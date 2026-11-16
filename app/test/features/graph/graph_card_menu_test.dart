// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_card_menu.dart';
import 'package:zanshin/src/features/graph/graph_card_render.dart';
import 'package:zanshin/src/features/graph/graph_drag.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_move_sheet.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart' show DiffContext;
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/fake_window_actions.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

final _en = AppLocalizationsEn();

const _at = 'wwwwwwwwwwww';
// The fixture card of test-fixtures/commands/card-menu.txt: unique prefix 2, shown as `kmnvxoqp`.
const _b = 'kmnvxoqpzzzzzzzzzzzzzzzzzzzzzzzz';
const _side = 'ssssssssssss';
const _empty = 'aaaaaaaaaaaa';
const _merge = 'mmmmmmmmmmmm';
const _imm = 'iiiiiiiiiiii';
const _immChild = 'jjjjjjjjjjjj';
const _root = 'zzzzzzzzzzzz';
const _immParent = 'kkkkkkkkkkkk';
const _onImm = 'pppppppppppp';

const _keys = <String>[_at, _b, _side, _empty, _merge, _imm, _immChild, _root, _immParent, _onImm];

/// @ → B → A (empty) → the merge of I and J (both immutable); S beside B on A; I → root; J → K (immutable) → root;
/// P on I.
RecordedGraphLayout _layout() {
  const int imm = RecordedGraphLayout.flagImmutable;
  return handLayout(
    <(String, int, int)>[
      (_at, 6, 0),
      (_b, 5, 0),
      (_side, 5, 1),
      (_empty, 4, 0),
      (_merge, 3, 0),
      (_imm, 2, 0),
      (_immChild, 2, 1),
      (_root, 0, 0),
      (_immParent, 1, 1),
      (_onImm, 3, 2),
    ],
    edges: <(int, int)>[(0, 1), (1, 3), (2, 3), (3, 4), (4, 5), (4, 6), (5, 7), (6, 8), (8, 7), (9, 5)],
    workingCopy: 0,
    root: 7,
    parentCounts: const <int>[1, 1, 1, 1, 2, 1, 1, 0, 1, 1],
    flags: const <int>[0, 0, 0, 0, 0, imm, imm, imm, imm, 0],
    prefixLengths: const <int>[1, 2, 1, 1, 1, 1, 1, 1, 1, 1],
    commitIds: <String>[for (final String key in _keys) 'c$key'],
    refs: <List<GraphRef>>[
      for (final String key in _keys)
        if (key == _b)
          const <GraphRef>[GraphRef('b-mark'), GraphRef('b-mark', remote: 'origin'), GraphRef('b-mark', remote: 'git')]
        else
          const <GraphRef>[],
    ],
    tags: <List<GraphRef>>[
      for (final String key in _keys)
        if (key == _b) const <GraphRef>[GraphRef('v1'), GraphRef('v2')] else const <GraphRef>[],
    ],
    contents: <GraphCommitContent?>[
      for (final String key in _keys)
        if (key == _root)
          null
        else
          GraphCommitContent(subject: 'about $key', description: 'about $key\n', empty: key == _empty),
    ],
    operationId: 'op0',
  );
}

final GraphLayout _l = _layout();

int _node(String key) => _l.indexOfKey(key)!;

List<ZsMenuEntry> _menu(
  String key, {
  String? blocked,
  ValueChanged<GraphAction>? run,
  ValueChanged<String>? onDescribe,
  ValueChanged<String>? onSquash,
  VoidCallback? onImmutableCommits,
  ValueChanged<GraphSheetRequest>? ask,
}) => graphCardMenuEntries(
  _en,
  _l,
  _node(key),
  blocked: blocked,
  run: run ?? (_) {},
  onDescribe: onDescribe ?? (_) {},
  onSquash: onSquash,
  onImmutableCommits: onImmutableCommits,
  ask: ask ?? (_) {},
);

List<ZsMenuItem> _items(List<ZsMenuEntry> entries) => entries.whereType<ZsMenuItem>().toList();

ZsMenuItem _row(List<ZsMenuEntry> entries, String label) => _items(entries).singleWhere((i) => i.label == label);

/// The label of each entry: a row's label, `—` for a separator, `note: …` for a note.
List<String> _shape(List<ZsMenuEntry> entries) => <String>[
  for (final ZsMenuEntry entry in entries)
    switch (entry) {
      ZsMenuItem(:final String label) => label,
      ZsMenuSeparator() => '—',
      ZsMenuNote(:final String label) => 'note: $label',
      ZsMenuHeader(:final String label) => 'header: $label',
    },
];

List<ZsMenuEntry> _popover({
  List<Bookmark>? bookmarks,
  String? blocked,
  ValueChanged<GraphAction>? run,
  ValueChanged<GraphSheetRequest>? ask,
}) => graphBookmarkMenuEntries(
  _en,
  _l,
  _node(_b),
  blocked: blocked,
  run: run ?? (_) {},
  bookmarks: bookmarks,
  ask: ask ?? (_) {},
);

List<Bookmark> _rows({required bool tracked}) => <Bookmark>[
  localRow('b-mark', 'c$_b'),
  remoteRow('b-mark', 'origin', 'c$_b', tracked: tracked),
];

/// The requests Create…, Move existing here… and the bookmark's Rename… and Move to… ask for, by label.
Map<String, GraphSheetRequest> _requests() {
  final asked = <GraphSheetRequest>[];
  final List<ZsMenuEntry> entries = _popover(bookmarks: _rows(tracked: false), ask: asked.add);
  final List<ZsMenuEntry> local = _row(entries, 'b-mark').submenu!;
  for (final item in <ZsMenuItem>[
    _row(local, 'Rename…'),
    _row(local, 'Move to…'),
    _row(entries, 'Create bookmark here…'),
    _row(entries, 'Move existing here…'),
  ]) {
    item.onSelected!();
  }
  return <String, GraphSheetRequest>{
    'rename': asked[0],
    'moveTo': asked[1],
    'create': asked[2],
    'moveHere': asked[3],
  };
}

GraphNameRequest _nameRequest(String label) => _requests()[label]! as GraphNameRequest;

/// Previews every bookmark move as not a fast-forward.
class _BackwardsDrops implements GraphDrops {
  @override
  Future<DropActions> dropActions(DropSource source, List<DropLocation> locations) async => const DropActions(
    actions: <DropAction>[
      DropAction(
        verb: DropVerb.bookmarkMove,
        location: 0,
        outcome: ActionOutcome(
          status: ActionStatus.available,
          refusal: null,
          combinedDescriptionNeeded: false,
          allowBackwardsNeeded: true,
        ),
      ),
    ],
  );
}

/// Runs every action and writes one operation each.
class _Actions implements GraphActions {
  final ran = <GraphAction>[];

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    return MutationResult(
      newOpId: 'op${ran.length}',
      committed: true,
      newChangeIds: const <String>[],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }

  @override
  Future<AbsorbResult> absorb(String from) async => AbsorbResult(
    mutation: await run(GraphAbsorb(from)),
    rewrittenChangeIds: const <String>[],
    sourceChangeId: from,
    numRebased: 0,
    skippedPaths: const <SkippedPath>[],
  );
}

/// Reads that never answer: the inspector's fetch stays pending.
class _Details implements GraphDetails {
  @override
  Future<ShowEntry> show(String commitId) => Completer<ShowEntry>().future;

  @override
  Future<ChangeActions> changeActions(String changeId) => Completer<ChangeActions>().future;

  @override
  Future<Diff> diff(
    String commitId, {
    List<String> paths = const [],
    bool summary = false,
    DiffWhitespace whitespace = DiffWhitespace.exact,
  }) => Completer<Diff>().future;

  @override
  Future<List<HunkLine>> diffLines(
    String commitId, {
    required String path,
    required int start,
    required int end,
    DiffWhitespace whitespace = DiffWhitespace.exact,
  }) => Completer<List<HunkLine>>().future;

  @override
  Future<DiffContext> diffContext() async => (lines: 3, fromRepo: false);

  @override
  Future<void> setDiffContext(int lines) async {}

  /// Every plan asked for, by change id; none combines a description, so the squash runs at once.
  final plans = <String>[];

  @override
  Future<SquashPlan> squashPlan(String changeId) async {
    plans.add(changeId);
    return const SquashPlan(combinedDescription: null);
  }
}

void main() {
  setUpIconRegistry();

  group('graphCardMenuEntries', () {
    test('a mutable change: the rows, each command with the short id', () {
      final List<ZsMenuEntry> entries = _menu(_b);
      expect(_shape(entries), <String>[
        'New change on top',
        'Insert after',
        'Insert before',
        '—',
        'Edit',
        'Describe…',
        'Squash into parent',
        'Absorb into ancestors',
        'Copy',
        '—',
        'Revert',
        'Abandon',
        '—',
        'Create bookmark here…',
        'Create tag here…',
      ]);
      expect(_items(entries).every((i) => i.enabled), isTrue);
      expect(_row(entries, 'Absorb into ancestors').cmd, 'jj absorb --from kmnvxoqp');
      expect(_row(entries, 'Absorb into ancestors').icon, ZI.squashInto);
      expect(_row(entries, 'Revert').cmd, 'jj revert -r kmnvxoqp -B @', reason: 'B is an ancestor of @');
      expect(_row(entries, 'Abandon').danger, isTrue);
      expect(_row(entries, 'Copy').submenu!.map((e) => (e as ZsMenuItem).label), <String>['Change id', 'Description']);
      expect(_row(entries, 'Copy').cmd, isNull);
    });

    test('every enabled row runs its action with the full key', () {
      final ran = <GraphAction>[];
      final described = <String>[];
      final List<ZsMenuEntry> entries = _menu(_b, run: ran.add, onDescribe: described.add);
      for (final ZsMenuItem item in _items(entries)) {
        if (item.submenu == null) {
          item.onSelected!();
        }
      }
      expect(described, <String>[_b]);
      expect(ran.map((a) => a.command), <String>[
        'jj new $_b',
        'jj new -A $_b',
        'jj new -B $_b',
        'jj edit $_b',
        'jj squash -r $_b',
        'jj absorb --from $_b',
        'jj revert -r $_b -B @',
        'jj abandon $_b',
      ]);
      expect(ran.last, isA<GraphAbandon>().having((a) => a.ids, 'ids', <String>[_b]));
    });

    test('with onSquash, Squash into parent calls it with the key instead of running (Story 10.25)', () {
      final ran = <GraphAction>[];
      final squashed = <String>[];
      final ZsMenuItem row = _row(_menu(_b, run: ran.add, onSquash: squashed.add), 'Squash into parent');
      expect(row.cmd, 'jj squash -r kmnvxoqp');
      row.onSelected!();
      expect(squashed, <String>[_b]);
      expect(ran, isEmpty);
    });

    test('@: Edit and Revert disabled with their reasons', () {
      final List<ZsMenuEntry> entries = _menu(_at);
      expect(_row(entries, 'Edit').enabled, isFalse);
      expect(_row(entries, 'Edit').tooltip, 'Already the working copy');
      expect(_row(entries, 'Revert').enabled, isFalse);
      expect(_row(entries, 'Revert').tooltip, "The revert lands below @ — @ itself can't be reverted");
      expect(_row(entries, 'Abandon').enabled, isTrue);
    });

    test("Revert: off outside @'s history and on an empty change", () {
      expect(_row(_menu(_side), 'Revert').tooltip, "The revert lands below @ — only changes in @'s history");
      expect(_row(_menu(_empty), 'Revert').tooltip, 'Nothing to revert — the change is empty');
    });

    test('Squash: off on a merge and on an immutable parent', () {
      expect(_row(_menu(_merge), 'Squash into parent').tooltip, 'A merge has more than one parent');
      expect(_row(_menu(_onImm), 'Squash into parent').tooltip, 'The parent is immutable');
      expect(_row(_menu(_b), 'Squash into parent').tooltip, isNull);
    });

    test('Absorb into ancestors carries no preview: on where Squash is off (Story 10.36)', () {
      for (final key in <String>[_merge, _onImm, _at]) {
        expect(_row(_menu(key), 'Absorb into ancestors').enabled, isTrue, reason: key);
      }
    });

    test('an immutable change: the locked menu; Insert after only without an immutable child', () {
      final List<ZsMenuEntry> entries = _menu(_imm);
      expect(_shape(entries), <String>[
        'New change on top',
        'Insert after',
        'Revert',
        '—',
        'note: Immutable',
        'Immutable commits…',
        '—',
        'Create bookmark here…',
        'Create tag here…',
      ]);
      expect(_row(entries, 'Revert').enabled, isTrue, reason: 'an immutable ancestor of @');
      expect((entries[4] as ZsMenuNote).leading, isNotNull);
      expect(_row(entries, 'Immutable commits…').enabled, isFalse, reason: 'no window actions');
      expect(_row(entries, 'Immutable commits…').icon, ZI.settings);
      var opened = 0;
      final ZsMenuItem open = _row(_menu(_imm, onImmutableCommits: () => opened++), 'Immutable commits…');
      expect(open.enabled, isTrue);
      open.onSelected!();
      expect(opened, 1, reason: "Story 11.7: Settings' Immutable commits page");
      expect(_shape(_menu(_immParent)), <String>[
        'New change on top',
        'Revert',
        '—',
        'note: Immutable',
        'Immutable commits…',
        '—',
        'Create bookmark here…',
        'Create tag here…',
      ]);
    });

    test('Story 10.45: the last group creates a bookmark or a tag through the name sheet; disabled without one', () {
      for (final key in <String>[_b, _imm]) {
        final asked = <GraphNameRequest>[];
        final List<ZsMenuEntry> entries = _menu(key, ask: (r) => asked.add(r as GraphNameRequest));
        final ZsMenuItem bookmark = _row(entries, 'Create bookmark here…');
        final ZsMenuItem tag = _row(entries, 'Create tag here…');
        expect((bookmark.icon, bookmark.identifier), (ZI.bookmark, 'card-menu-create-bookmark'), reason: key);
        expect((tag.icon, tag.identifier), (ZI.tag, 'card-menu-create-tag'), reason: key);
        final short = key == _b ? 'kmnvxoqp' : 'iiiiiiii';
        expect((bookmark.cmd, tag.cmd), (null, null), reason: 'the name sheet shows the live command');
        bookmark.onSelected!();
        tag.onSelected!();
        expect(asked.map((r) => r.title), <String>['Create bookmark here', 'Create tag here']);
        expect(asked.map((r) => r.label), <String>['Bookmark name', 'Tag name']);
        expect(asked[0].action('x', key), isA<GraphBookmarkCreate>().having((a) => a.revision, 'revision', key));
        expect(asked[1].action('v9', short).command, 'jj tag set v9 -r $short');
      }
      final ZsMenuItem without = _row(
        graphCardMenuEntries(_en, _l, _node(_b), blocked: null, run: (_) {}),
        'Create tag here…',
      );
      expect(without.enabled, isFalse, reason: 'no name sheet');
    });

    test('the root: New change on top only', () {
      expect(_shape(_menu(_root)), <String>['New change on top']);
      expect(_row(_menu(_root), 'New change on top').cmd, 'jj new zzzzzzzz');
    });

    test('busy or stale: every jj row disabled with the reason; nothing runs; Copy stays on', () {
      final ran = <GraphAction>[];
      for (final key in <String>[_b, _imm, _root]) {
        for (final ZsMenuItem item in _items(_menu(key, blocked: 'Another action is running', run: ran.add))) {
          if (item.label == 'Copy') {
            expect(item.enabled, isTrue, reason: 'read-only');
            expect(item.submenu!.every((e) => (e as ZsMenuItem).enabled), isTrue);
            continue;
          }
          if (item.label == 'Immutable commits…') {
            // Opens Settings, no jj action; enabled whenever the window actions are there.
            continue;
          }
          expect(item.enabled, isFalse, reason: '$key ${item.label}');
          expect(item.tooltip, 'Another action is running', reason: '$key ${item.label}');
        }
      }
      expect(ran, isEmpty);
    });

    test('Copy › Change id and Description write the full id and description; Description waits for content', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final copied = <String?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final List<ZsMenuEntry> copy = _row(_menu(_b), 'Copy').submenu!;
      _row(copy, 'Change id').onSelected!();
      _row(copy, 'Description').onSelected!();
      await Future<void>.delayed(Duration.zero);
      expect(copied, <String>[_b, 'about $_b\n']);

      final GraphLayout bare = handLayout(<(String, int, int)>[(_b, 0, 0)], changeIds: const <String>[_b]);
      final ZsMenuItem description = _row(
        _row(graphCardMenuEntries(_en, bare, 0, blocked: null, run: (_) {}), 'Copy').submenu!,
        'Description',
      );
      expect(description.enabled, isFalse, reason: 'no content yet');
    });
  });

  group('graphBookmarkMenuEntries', () {
    test('a local bookmark: Rename…, Move to…, Delete; the remote row waits for the read; git is left out', () {
      final List<ZsMenuEntry> entries = _popover();
      expect(_shape(entries), <String>['b-mark', 'b-mark@origin', '—', 'Create bookmark here…', 'Move existing here…']);
      expect(_row(entries, 'b-mark').mono, isTrue);
      expect(_shape(_row(entries, 'b-mark').submenu!), <String>['Rename…', 'Move to…', 'Delete']);
      expect(_row(entries, 'b-mark@origin').enabled, isFalse);
      expect(_row(entries, 'b-mark@origin').tooltip, 'Reading bookmarks…');
    });

    test('Track for an untracked remote, Untrack for a tracked one; Delete', () {
      final ran = <GraphAction>[];
      final List<ZsMenuEntry> untracked = _popover(bookmarks: _rows(tracked: false), run: ran.add);
      final ZsMenuItem track = _row(_row(untracked, 'b-mark@origin').submenu!, 'Track');
      track.onSelected!();
      expect(
        ran.single,
        isA<GraphBookmarkTrack>().having((a) => a.name, 'name', 'b-mark').having((a) => a.remote, 'remote', 'origin'),
      );
      final List<ZsMenuEntry> tracked = _popover(bookmarks: _rows(tracked: true), run: ran.add);
      expect(_shape(_row(tracked, 'b-mark@origin').submenu!), <String>['Untrack']);
      _row(_row(untracked, 'b-mark').submenu!, 'Delete').onSelected!();
      expect(ran.last, isA<GraphBookmarkDelete>().having((a) => a.names, 'names', <String>['b-mark']));
    });

    test('Story 10.44: with the delete flow, Delete… hands the name over; a failed read or a block disables it', () {
      final deleted = <String>[];
      final ran = <GraphAction>[];
      ZsMenuItem delete({required bool readFailed, String? blocked}) => _row(
        _row(
          graphBookmarkMenuEntries(
            _en,
            _l,
            _node(_b),
            blocked: blocked,
            run: ran.add,
            bookmarks: readFailed ? null : _rows(tracked: true),
            readFailed: readFailed,
            ask: (_) {},
            delete: deleted.add,
          ),
          'b-mark',
        ).submenu!,
        'Delete…',
      );
      final ZsMenuItem item = delete(readFailed: false);
      expect((item.enabled, item.cmd, item.danger), (true, 'jj bookmark delete b-mark', true));
      item.onSelected!();
      expect(deleted, <String>['b-mark']);
      expect(ran, isEmpty, reason: 'the flow runs it');
      final ZsMenuItem failed = delete(readFailed: true);
      expect((failed.enabled, failed.tooltip), (false, "Couldn't read the bookmarks"));
      final ZsMenuItem stale = delete(readFailed: false, blocked: 'stale');
      expect((stale.enabled, stale.tooltip), (false, 'stale'));
    });

    test('Create… asks for a name; the action names the change', () {
      final GraphNameRequest create = _nameRequest('create');
      expect(create.title, 'Create bookmark here');
      expect(create.action('x', _b), isA<GraphBookmarkCreate>().having((a) => a.revision, 'revision', _b));
    });

    test(
      'Story 10.46: Rename… and Create… take a ref name, Move to… a revision; Move existing here… asks the picker',
      () {
        expect(_nameRequest('rename').refName, isTrue);
        expect(_nameRequest('create').refName, isTrue);
        expect(_nameRequest('moveTo').refName, isFalse);
        expect(_requests()['moveHere'], isA<GraphMoveRequest>().having((r) => r.tag, 'tag', false));
      },
    );

    test('a failed read: the remote row disabled with the failure', () {
      final ZsMenuItem remote = _row(
        graphBookmarkMenuEntries(
          _en,
          _l,
          _node(_b),
          blocked: null,
          run: (_) {},
          bookmarks: null,
          readFailed: true,
          ask: (_) {},
        ),
        'b-mark@origin',
      );
      expect(remote.enabled, isFalse);
      expect(remote.tooltip, "Couldn't read the bookmarks");
    });

    test('busy: every row disabled', () {
      for (final ZsMenuItem item in _items(_popover(bookmarks: _rows(tracked: false), blocked: 'stale'))) {
        expect(item.enabled, isFalse, reason: item.label);
        expect(item.tooltip, 'stale');
      }
    });
  });

  group('graphTagMenuEntries (Story 10.45)', () {
    final GraphLayout tagged = handLayout(
      <(String, int, int)>[(_b, 0, 0)],
      changeIds: const <String>[_b],
      prefixLengths: const <int>[2],
      tags: const <List<GraphRef>>[
        <GraphRef>[
          GraphRef('v1'),
          GraphRef('v2'),
          GraphRef('v1', remote: 'origin'),
          GraphRef('v1', remote: 'git'),
        ],
      ],
    );
    final tagRows = <Bookmark>[
      localRow('v1', 'c$_b'),
      remoteRow('v1', 'origin', 'c$_b'),
      remoteRow('v1', 'git', 'c$_b'),
      localRow('v2', 'c$_b'),
      remoteRow('v2', 'upstream', null, tracked: false),
    ];

    List<ZsMenuEntry> tags({
      List<Bookmark>? rows,
      bool readFailed = false,
      String? blocked,
      ValueChanged<GraphAction>? run,
      ValueChanged<GraphSheetRequest>? ask,
      ValueChanged<String>? delete,
    }) => graphTagMenuEntries(
      _en,
      tagged,
      0,
      blocked: blocked,
      run: run ?? (_) {},
      tags: rows,
      readFailed: readFailed,
      ask: ask ?? (_) {},
      delete: delete,
    );

    test('a row per local tag with its state, the remote tag (not git), then Create and Move', () {
      final List<ZsMenuEntry> entries = tags(rows: tagRows);
      expect(_shape(entries), <String>['v1', 'v2', 'v1@origin', '—', 'Create tag here…', 'Move existing here…']);
      expect(_row(entries, 'v1').shortcut, 'on origin');
      expect(_row(entries, 'v2').shortcut, 'local only', reason: 'a remote row without a target holds nothing');
      expect(_row(entries, 'v1').mono, isTrue);
      expect(_row(entries, 'v1').identifier, 'tag-menu-v1');
      expect(_items(entries).every((i) => i.enabled), isTrue);
    });

    test('while the read is pending "Reading tags…", after a failure the failure; Delete… then off', () {
      final List<ZsMenuEntry> pending = tags(delete: (_) {});
      expect(_row(pending, 'v1').shortcut, 'Reading tags…');
      expect(_row(pending, 'v1@origin').enabled, isFalse);
      expect(_row(_row(pending, 'v1').submenu!, 'Delete…').enabled, isTrue, reason: 'the flow reads first');
      final List<ZsMenuEntry> failed = tags(readFailed: true, delete: (_) {});
      expect(_row(failed, 'v2').shortcut, "Couldn't read the tags");
      final ZsMenuItem delete = _row(_row(failed, 'v1').submenu!, 'Delete…');
      expect((delete.enabled, delete.tooltip), (false, "Couldn't read the tags"));
    });

    test('Delete… goes to the delete flow, or runs jj tag delete without one', () {
      final deleted = <String>[];
      final ran = <GraphAction>[];
      final ZsMenuItem flow = _row(_row(tags(rows: tagRows, delete: deleted.add), 'v1').submenu!, 'Delete…');
      expect((flow.cmd, flow.danger, flow.identifier), ('jj tag delete v1', true, 'tag-menu-delete'));
      flow.onSelected!();
      expect(deleted, <String>['v1']);
      _row(_row(tags(rows: tagRows, run: ran.add), 'v2').submenu!, 'Delete…').onSelected!();
      expect(ran.single, isA<GraphTagDelete>().having((a) => a.names, 'names', <String>['v2']));
    });

    test('Track or Untrack the remote tag as the read says', () {
      final ran = <GraphAction>[];
      _row(_row(tags(rows: tagRows, run: ran.add), 'v1@origin').submenu!, 'Untrack').onSelected!();
      expect(ran.last.command, 'jj tag untrack v1@origin');
      final untracked = <Bookmark>[localRow('v1', 'c$_b'), remoteRow('v1', 'origin', 'c$_b', tracked: false)];
      _row(_row(tags(rows: untracked, run: ran.add), 'v1@origin').submenu!, 'Track').onSelected!();
      expect(ran.last.command, 'jj tag track v1@origin');
    });

    test('Create tag here… asks for a name (jj tag set -r), Move existing here… for the tag picker', () {
      final asked = <GraphSheetRequest>[];
      final List<ZsMenuEntry> entries = tags(rows: tagRows, ask: asked.add);
      _row(entries, 'Create tag here…').onSelected!();
      _row(entries, 'Move existing here…').onSelected!();
      final create = asked[0] as GraphNameRequest;
      expect((create.title, create.refName), ('Create tag here', true));
      expect(create.action('v9', 'kmnvxoqp').command, 'jj tag set v9 -r kmnvxoqp');
      expect(asked[1], isA<GraphMoveRequest>().having((r) => r.tag, 'tag', true));
    });

    test('busy: every row disabled with the reason', () {
      for (final ZsMenuItem item in _items(tags(rows: tagRows, blocked: 'stale'))) {
        expect((item.enabled, item.tooltip), (false, 'stale'), reason: item.label);
      }
    });
  });

  test('test-fixtures/commands/card-menu.txt holds the commands the menu, the popover and the sheets show', () {
    final List<ZsMenuEntry> menu = _menu(_b);
    final ZsMenuItem local = _row(_popover(bookmarks: _rows(tracked: false)), 'b-mark');
    const short = 'kmnvxoqp';
    // Story 10.45: the card menu's Create tag here….
    final tagSheets = <GraphSheetRequest>[];
    _row(_menu(_b, ask: tagSheets.add), 'Create tag here…').onSelected!();
    final commands = <String>[
      for (final ZsMenuItem item in _items(menu))
        if (item.cmd case final String cmd) cmd,
      _row(local.submenu!, 'Delete').cmd!,
      _row(_row(_popover(bookmarks: _rows(tracked: false)), 'b-mark@origin').submenu!, 'Track').cmd!,
      _row(_row(_popover(bookmarks: _rows(tracked: true)), 'b-mark@origin').submenu!, 'Untrack').cmd!,
      _nameRequest('rename').action('feature/x', short).command,
      _nameRequest('moveTo').action('@', short).command,
      _nameRequest('create').action('ü', short).command,
      // Story 10.46: the move picker's commands, forward and with --allow-backwards.
      graphMoveAction(tag: false, name: 'b-mark', id: short).command,
      graphMoveAction(tag: false, name: 'b-mark', id: short, allowBackwards: true).command,
      (tagSheets.single as GraphNameRequest).action('ü', short).command,
      graphMoveAction(tag: true, name: 'v1', id: short).command,
    ];
    final List<String> lines = File('../test-fixtures/commands/card-menu.txt').readAsLinesSync();
    expect(commands, lines);
  });

  group('in the graph', () {
    late ScriptedGraphSource source;
    late GraphViewModel model;
    late _Actions actions;
    InspectorViewModel? inspector;
    late Widget view;
    const ZsMotion m = ZsMotion.full;

    Future<void> pump(
      WidgetTester tester, {
      Future<List<Bookmark>> Function()? bookmarks,
      AppWindowActions? windowActions,
      GraphDeleteBookmark? deleteBookmark,
      Future<List<Bookmark>> Function()? tags,
      GraphDeleteBookmark? deleteTag,
      bool textShortcuts = false,
      GraphDrops? drops,
    }) async {
      source = ScriptedGraphSource(respond: (_) => _layout());
      actions = _Actions();
      model = GraphViewModel()
        ..init(source, actions: actions, drops: drops, clock: () => DateTime.utc(2026, 10, 30, 12));
      final Directory dir = Directory.systemTemp.createTempSync('zanshin_card_menu');
      addTearDown(() => dir.deleteSync(recursive: true));
      final SettingsStore settings = await SettingsStore.load(File('${dir.path}/settings.json'));
      inspector = InspectorViewModel(
        graph: model,
        details: _Details(),
        viewed: ProjectViewedStore(settings, '/r'),
        settings: settings,
      );
      tester.view
        ..physicalSize = surface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      view = GraphView(
        model: model,
        inspectorModel: inspector,
        bookmarks: bookmarks,
        deleteBookmark: deleteBookmark,
        tags: tags,
        deleteTag: deleteTag,
      );
      final Widget host = shellHost(
        windowActions == null ? view : AppWindowActionsScope(actions: windowActions, child: view),
      );
      // The app's WidgetsApp brings the text shortcuts (⌘V); the shell host does not.
      await tester.pumpWidget(textShortcuts ? DefaultTextEditingShortcuts(child: host) : host);
      await tester.pump();
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      inspector?.dispose();
      model.dispose();
    }

    GraphCardController cards(WidgetTester tester) => tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards;

    Finder card(String key) =>
        find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(m.durMenu);
      await tester.pump(m.durExit);
    }

    testWidgets('a right-click opens the menu at the pointer; Esc closes it and clears menuOpen', (tester) async {
      await pump(tester);
      // @, the top card: its menu fits below the pointer.
      final Offset at = tester.getCenter(card(_at));
      await tester.tapAt(at, buttons: kSecondaryButton);
      await settle(tester);
      expect(cards(tester).menuOpen.value, _at);
      expect(find.text('Insert before'), findsOneWidget);
      expect(find.text('about $_at'), findsOneWidget, reason: 'the subject heads the menu');
      final Rect panel = tester.getRect(find.byType(ZsMenuMaterial));
      expect(panel.topLeft, at, reason: 'at the pointer');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(cards(tester).menuOpen.value, isNull);
      await finish(tester);
    });

    testWidgets('openMenu twice opens then closes; a scroll and a new selection close it', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester);
      // @, the top card: its menu fits below the anchor.
      final more = Rect.fromCenter(center: tester.getCenter(card(_at)), width: 18, height: 18);
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.text('Insert before'), findsOneWidget);
      expect(tester.getRect(find.byType(ZsMenuMaterial)).top, more.bottom + 4, reason: 'below the anchor');
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(c.menuOpen.value, isNull);

      c.openMenu(_b, more);
      await settle(tester);
      // Over the graph beside the menu, which hangs from the anchor to the right.
      final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(more.bottomLeft + const Offset(-40, 60));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(c.menuOpen.value, isNull);

      c.openMenu(_b, more);
      await settle(tester);
      c.select(_side);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      await tester.pump(graphDoubleClickWindow);
      await finish(tester);
    });

    testWidgets("Story 11.7: an immutable card's Immutable commits… opens Settings on that page", (tester) async {
      final windows = FakeWindowActions();
      await pump(tester, windowActions: windows);
      cards(tester).openMenu(_imm, Rect.fromCenter(center: tester.getCenter(card(_imm)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Immutable commits…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(windows.settings, <SettingsTarget?>[SettingsTarget.immutableCommits]);
      await finish(tester);
    });

    testWidgets('Abandon runs GraphAbandon with the key and closes the menu; Describe… opens the form', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester)
        ..openMenu(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Abandon'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(actions.ran.single, isA<GraphAbandon>().having((a) => a.ids, 'ids', <String>[_b]));
      expect(c.menuOpen.value, isNull);
      expect(find.text('Insert before'), findsNothing);
      await tester.pump();
      await tester.pump();

      c.openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Describe…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(model.selected, _side);
      expect(inspector!.isOpen(_side), isTrue);
      await finish(tester);
    });

    testWidgets('Squash into parent goes through the inspector: it selects the change, asks the plan, squashes', (
      tester,
    ) async {
      await pump(tester);
      cards(tester).openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Squash into parent'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(model.selected, _side);
      expect((inspector!.details as _Details).plans, <String>[_side]);
      expect(actions.ran.single, isA<GraphSquash>().having((a) => a.revision, 'revision', _side));
      await finish(tester);
    });

    testWidgets("in the real fonts Revert's command reads in full and the menu stays within 360", (tester) async {
      // The test font draws every glyph as wide as its size; the limits are for Inter and JetBrains Mono.
      await tester.runAsync(() async {
        for (final (String family, String asset) in <(String, String)>[
          (ZsType.sansFamily, 'packages/zanshin_ui/assets/fonts/Inter/Inter-VariableFont_opsz,wght.ttf'),
          (ZsType.monoFamily, 'packages/zanshin_ui/assets/fonts/JetBrains_Mono/JetBrainsMono-VariableFont_wght.ttf'),
        ]) {
          await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
        }
      });
      await pump(tester);
      cards(tester).openMenu(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18));
      await settle(tester);
      const revert = 'jj revert -r kmnvxoqp -B @';
      expect(tester.renderObject<RenderParagraph>(find.text(revert)).didExceedMaxLines, isFalse);
      expect(tester.getSize(find.byType(ZsMenuMaterial)).width, lessThanOrEqualTo(360));
      await finish(tester);
    });

    testWidgets('an open menu closes when the window turns inactive and when the view size changes', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester);
      final more = Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18);
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      await tester.pumpWidget(shellHost(view, appearance: const ZsAppearance(inactive: true)));
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);

      await tester.pumpWidget(shellHost(view));
      await settle(tester);
      c.openMenu(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18));
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      tester.view.physicalSize = const Size(900, 640);
      await tester.pump();
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);
      await finish(tester);
    });

    testWidgets("a reload whose layout lacks the open card's key closes its menu", (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester)
        ..openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      source
        ..respond = ((_) => handLayout(
          <(String, int, int)>[(_at, 1, 0), (_root, 0, 0)],
          edges: const <(int, int)>[(0, 1)],
          workingCopy: 0,
          root: 1,
          flags: const <int>[0, RecordedGraphLayout.flagImmutable],
          operationId: 'op1',
        ))
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);
      await finish(tester);
    });

    testWidgets('Story 10.10: a local bookmark row of the popover drags; the popover closes, the drag goes on', (
      tester,
    ) async {
      await pump(tester, bookmarks: () async => _rows(tracked: false));
      final GraphCardController c = cards(tester)
        ..openBookmarks(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
      await settle(tester);
      final Offset row = tester.getCenter(find.text('b-mark'));
      final TestGesture mouse = await tester.startGesture(row, kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(30, 30));
      await settle(tester);
      expect(model.drag.payload, isA<GraphBookmarkDrag>().having((p) => p.name, 'name', 'b-mark'));
      expect(c.bookmarksOpen.value, isNull, reason: 'the drag start closes the popover');
      await mouse.moveBy(const Offset(30, 30));
      await tester.pump();
      expect(model.drag.active, isTrue, reason: 'the drag follows the mouse without its row');
      await mouse.up();
      await settle(tester);
      expect(model.drag.payload, isNull);
      expect(actions.ran, isEmpty);
      await finish(tester);
    });

    testWidgets('Story 10.44: the popover\'s Delete goes to the delete flow with the --all-remotes rows', (
      tester,
    ) async {
      final deleted = <(String, List<Bookmark>)>[];
      await pump(
        tester,
        bookmarks: () async => _rows(tracked: true),
        deleteBookmark: (name, rows) => deleted.add((name, rows)),
      );
      cards(tester).openBookmarks(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
      await settle(tester);
      await tester.tap(find.text('b-mark'));
      await settle(tester);
      await tester.tap(find.text('Delete…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(deleted.single.$1, 'b-mark');
      expect(deleted.single.$2.map((b) => b.kind is RemoteBookmark), <bool>[false, true]);
      expect(actions.ran, isEmpty, reason: 'the flow decides what runs');
      await finish(tester);
    });

    testWidgets('Story 10.44: Delete before the read lands waits for it; a failed read deletes nothing', (
      tester,
    ) async {
      var read = Completer<List<Bookmark>>();
      final deleted = <(String, List<Bookmark>)>[];
      await pump(
        tester,
        bookmarks: () => read.future,
        deleteBookmark: (name, rows) => deleted.add((name, rows)),
      );
      Future<void> tapDelete() async {
        cards(tester).openBookmarks(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
        await settle(tester);
        await tester.tap(find.text('b-mark'));
        await settle(tester);
        await tester.tap(find.text('Delete…'));
        await tester.pump(m.durBlink);
        await tester.pump(m.durBlink);
        await settle(tester);
      }

      await tapDelete();
      expect(deleted, isEmpty, reason: 'the read has not landed');
      read.complete(_rows(tracked: true));
      await tester.pump();
      expect(deleted.single.$1, 'b-mark');
      expect(
        deleted.single.$2
            .where((b) => b.kind is RemoteBookmark && (b.kind as RemoteBookmark).tracked)
            .map((b) => b.name),
        <String>['b-mark'],
        reason: 'the flow gets the tracked remote row',
      );

      deleted.clear();
      read = Completer<List<Bookmark>>();
      await tapDelete();
      read.completeError(const ZanshinFfiException('jj.io_error', 'disk'));
      await tester.pump();
      await tester.pump();
      expect(deleted, isEmpty);
      // The popover now knows the read failed: Delete is disabled with the failure, so a tap deletes nothing.
      await tapDelete();
      await tester.pump();
      expect(deleted, isEmpty);
      await finish(tester);
    });

    testWidgets('the popover: Track after the read; Create… asks in the name sheet and runs create', (tester) async {
      final read = Completer<List<Bookmark>>();
      await pump(tester, bookmarks: () => read.future);
      final GraphCardController c = cards(tester);
      final pill = Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16);
      c.openBookmarks(_b, pill);
      await settle(tester);
      expect(find.text('b-mark@origin'), findsOneWidget);
      read.complete(_rows(tracked: false));
      await tester.pump();
      await tester.tap(find.text('b-mark@origin'));
      await settle(tester);
      await tester.tap(find.text('Track'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(actions.ran.single, isA<GraphBookmarkTrack>().having((a) => a.symbol, 'symbol', 'b-mark@origin'));
      expect(c.bookmarksOpen.value, isNull);
      await tester.pump();
      await tester.pump();

      c.openBookmarks(_b, pill);
      await settle(tester);
      await tester.tap(find.text('Create bookmark here…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await tester.pump();
      await tester.pump(m.durPop);
      expect(find.byType(GraphNameSheet), findsOneWidget);
      final ZsButton confirm = tester.widget<ZsButton>(
        find.byWidgetPredicate((w) => w is ZsButton && w.identifier == 'name-sheet-confirm'),
      );
      expect(confirm.onPressed, isNull, reason: 'the field is empty');
      await tester.enterText(find.byType(EditableText), 'feature');
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('name-sheet-command'))).data,
        'jj bookmark create feature -r kmnvxoqp',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(m.durExitLg);
      await tester.pump();
      expect(
        actions.ran.last,
        isA<GraphBookmarkCreate>()
            .having((a) => a.names, 'names', <String>['feature'])
            .having((a) => a.revision, 'revision', _b),
      );
      expect(find.byType(GraphNameSheet), findsNothing);
      await finish(tester);
    });

    Future<void> tapRow(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await tester.pump();
      await tester.pump(m.durPop);
    }

    Future<void> confirmName(WidgetTester tester, String name) async {
      expect(find.byType(GraphNameSheet), findsOneWidget);
      await tester.enterText(find.byType(EditableText), name);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(m.durExitLg);
      await tester.pump();
    }

    testWidgets('Story 10.45: the card menu\'s Create tag here… and Create bookmark here… run through the name sheet', (
      tester,
    ) async {
      await pump(tester);
      final GraphCardController c = cards(tester);
      final at = Rect.fromCenter(center: tester.getCenter(card(_side)), width: 0, height: 0);
      c.openMenu(_side, at);
      await settle(tester);
      await tapRow(tester, 'Create tag here…');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('name-sheet-command'))).data,
        ' ',
        reason: 'no command while the field is empty',
      );
      await confirmName(tester, 'v9');
      expect(actions.ran.last.command, 'jj tag set v9 -r $_side');
      expect(find.byType(GraphNameSheet), findsNothing);

      c.openMenu(_side, at);
      await settle(tester);
      await tapRow(tester, 'Create bookmark here…');
      await confirmName(tester, 'feat');
      expect(actions.ran.last.command, 'jj bookmark create feat -r $_side');
      await finish(tester);
    });

    testWidgets('Story 10.45: the tag popover lists the tags with their state; Delete… goes to the delete flow; '
        'Move existing here… runs jj tag set --allow-move', (tester) async {
      final deleted = <(String, List<Bookmark>)>[];
      final rows = <Bookmark>[localRow('v1', 'c$_b'), remoteRow('v1', 'origin', 'c$_b'), localRow('v2', 'c$_b')];
      await pump(tester, tags: () async => rows, deleteTag: (name, rows) => deleted.add((name, rows)));
      final GraphCardController c = cards(tester);
      final RenderGraphCard render = tester.renderObject(card(_b));
      final Rect pill = render.debugSlots.firstWhere((s) => s.kind == GraphCardSlot.tagLegend).rect;
      await tester.tapAt(render.localToGlobal(pill.center));
      await settle(tester);
      expect(c.tagsOpen.value, _b, reason: 'a click on the pill opens it');
      expect(find.bySemanticsIdentifier('tag-menu'), findsWidgets);
      expect(find.text('on origin'), findsOneWidget);
      expect(find.text('local only'), findsOneWidget);
      expect(find.text('Create tag here…'), findsOneWidget);
      await tester.tap(find.text('v1'));
      await settle(tester);
      await tapRow(tester, 'Delete…');
      await settle(tester);
      expect(deleted.single.$1, 'v1');
      expect(deleted.single.$2, rows);
      expect(actions.ran, isEmpty, reason: 'the flow decides what runs');

      c.openTags(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
      await settle(tester);
      await tapRow(tester, 'Move existing here…');
      // Story 10.46: the tag picker; v1 is on origin, so it warns before it moves.
      expect(find.byType(GraphMoveSheet), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'v1');
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('move-sheet-published')), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(m.durExitLg);
      await tester.pump();
      expect(actions.ran.last.command, 'jj tag set v1 -r $_b --allow-move');
      expect(find.byType(GraphMoveSheet), findsNothing);
      await finish(tester);
    });

    testWidgets('Story 10.46: the bookmark popover\'s Move existing here… checks through the graph\'s drops; a '
        'backwards move runs only with --allow-backwards', (tester) async {
      await pump(tester, bookmarks: () async => _rows(tracked: false), drops: _BackwardsDrops());
      cards(tester).openBookmarks(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
      await settle(tester);
      await tapRow(tester, 'Move existing here…');
      expect(find.byType(GraphMoveSheet), findsOneWidget);
      await tester.pump();
      expect(find.text('backwards'), findsOneWidget);
      ZsButton move() => tester.widget<ZsButton>(
        find.byWidgetPredicate((w) => w is ZsButton && w.identifier == 'move-sheet-confirm'),
      );
      expect(move().onPressed, isNull);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('move-sheet-reason'))).data,
        'This move goes backwards: turn on the switch to allow it.',
      );
      await tester.tap(find.bySemanticsIdentifier('move-sheet-allow'));
      await tester.pump();
      await tester.tap(find.bySemanticsIdentifier('move-sheet-confirm'));
      await tester.pump();
      await tester.pump(m.durExitLg);
      await tester.pump();
      expect(actions.ran.last.command, 'jj bookmark move b-mark --to $_b --allow-backwards');
      await finish(tester);
    });

    group('Story 10.46: the name field', () {
      Future<void> openCreate(WidgetTester tester, {bool textShortcuts = false}) async {
        await pump(tester, textShortcuts: textShortcuts);
        cards(tester).openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 0, height: 0));
        await settle(tester);
        await tapRow(tester, 'Create bookmark here…');
      }

      String field(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).controller.text;
      Finder note() => find.byKey(const ValueKey<String>('name-sheet-replaced'));
      ZsButton confirm(WidgetTester tester) => tester.widget<ZsButton>(
        find.byWidgetPredicate((w) => w is ZsButton && w.identifier == 'name-sheet-confirm'),
      );

      testWidgets('typed: refused characters become _ with the note; emptying the field hides it', (tester) async {
        await openCreate(tester);
        expect(note(), findsNothing);
        await tester.enterText(find.byType(EditableText), 'feature/my new:idea?');
        await tester.pump();
        expect(field(tester), 'feature/my_new_idea_');
        expect(note(), findsOneWidget);
        expect(find.text('Spaces and ~ ^ : ? * [ \\ become _'), findsOneWidget);
        await tester.enterText(find.byType(EditableText), '');
        await tester.pump();
        expect(note(), findsNothing);
        await tester.enterText(find.byType(EditableText), 'feature');
        await tester.pump();
        expect(note(), findsNothing, reason: 'nothing replaced since the field was empty');
        await finish(tester);
      });

      testWidgets('a replacement that leaves the text as it was still shows the note', (tester) async {
        await openCreate(tester);
        await tester.enterText(find.byType(EditableText), 'a_b');
        await tester.pump();
        expect(note(), findsNothing);
        // A space typed over the selected `_`: the cleaned text equals the old one, so no onChanged fires.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'a b', selection: TextSelection.collapsed(offset: 2)),
        );
        await tester.pump();
        expect(field(tester), 'a_b');
        expect(note(), findsOneWidget);
        await finish(tester);
      });

      testWidgets('pasted with ⌘V: the same replacement', (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
            'Clipboard.getData' => <String, Object?>{'text': 'fix/login ~ crash'},
            'Clipboard.hasStrings' => <String, Object?>{'value': true},
            _ => null,
          },
        );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await openCreate(tester, textShortcuts: true);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        await tester.pump();
        expect(field(tester), 'fix/login___crash');
        expect(note(), findsOneWidget);
        await finish(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('a broken rule shows as the error, hides the note and turns Create and ↩ off', (tester) async {
        await openCreate(tester);
        await tester.enterText(find.byType(EditableText), 'release/1.5.');
        await tester.pump();
        expect(find.text('Must not end with “.”'), findsOneWidget);
        expect(note(), findsNothing, reason: 'the error wins');
        expect(confirm(tester).onPressed, isNull);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(actions.ran, isEmpty);
        expect(find.byType(GraphNameSheet), findsOneWidget);
        await tester.enterText(find.byType(EditableText), '@');
        await tester.pump();
        expect(find.text('Must not be “@” alone'), findsOneWidget);
        await tester.enterText(find.byType(EditableText), 'a@b');
        await tester.pump();
        expect(confirm(tester).onPressed, isNotNull, reason: '@ inside a name stays allowed');
        await finish(tester);
      });

      testWidgets('Move to… takes a revision as typed: no replacement, no rule', (tester) async {
        await pump(tester, bookmarks: () async => _rows(tracked: false));
        cards(tester).openBookmarks(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16));
        await settle(tester);
        await tester.tap(find.text('b-mark'));
        await settle(tester);
        await tapRow(tester, 'Move to…');
        await tester.enterText(find.byType(EditableText), '@- ');
        await tester.pump();
        expect(field(tester), '@- ');
        expect(note(), findsNothing);
        await tester.enterText(find.byType(EditableText), '@');
        await tester.pump();
        expect(find.text('Must not be “@” alone'), findsNothing);
        expect(confirm(tester).onPressed, isNotNull);
        await finish(tester);
      });
    });
  });
}
