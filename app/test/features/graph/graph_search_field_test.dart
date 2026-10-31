// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TextField;
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_field.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_graph_search_source.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

const _pause = Duration(milliseconds: 160);

/// `k0` (@) … `k3`, newest first; `k1` is Lena König's "Fix cache"; [extra] adds `hid1` (what `all()` shows more).
GraphLayout _layout({bool extra = false, String op = 'op1'}) {
  final keys = <String>['k0', 'k1', 'k2', 'k3', if (extra) 'hid1'];
  return handLayout(
    <(String, int, int)>[for (var i = 0; i < keys.length; i++) (keys[i], keys.length - 1 - i, 0)],
    edges: <(int, int)>[for (var i = 0; i + 1 < keys.length; i++) (i, i + 1)],
    workingCopy: 0,
    commitIds: <String>[for (final String k in keys) 'c$k'],
    prefixLengths: <int>[for (final _ in keys) 2],
    operationId: extra ? 'op-all' : op,
    contents: <GraphCommitContent?>[
      for (final String k in keys)
        GraphCommitContent(
          subject: k == 'k1' ? 'Fix cache' : 'Work $k',
          authorName: k == 'k1' ? 'Lena König' : 'Ralph',
          authorEmail: k == 'k1' ? 'lena@x.org' : 'ralph@x.org',
        ),
    ],
  );
}

class _Rig {
  _Rig({GraphShownView view = GraphShownView.defaultSearch, List<GraphRecent>? recent}) {
    source.respond = respond;
    store = MemoryGraphSearchStore(view: view, recent: recent);
    search = GraphSearchController(model: model, source: searchSource, store: store);
    model.init(source, clock: () => DateTime.utc(2026, 10, 31), revset: search.revset);
  }

  final source = ScriptedGraphSource();
  final searchSource = FakeGraphSearchSource();
  final model = GraphViewModel();
  final shell = ShellController();
  final other = ZsTextEditingController();
  final plain = FocusNode(debugLabel: 'plain');
  late final MemoryGraphSearchStore store;
  late final GraphSearchController search;

  GraphLayout Function(GraphRequest request) respond = (request) => _layout(extra: request.revset == 'all()');

  Widget host() => shellHost(
    GraphSearchShortcuts(
      search: search,
      child: Focus(
        focusNode: plain,
        child: FloatingShell(
          controller: shell,
          graph: GraphView(model: model),
          view: GraphSearchField(search: search),
          newChange: SizedBox(
            width: 120,
            child: ZsTextField(controller: other, label: 'Other'),
          ),
        ),
      ),
    ),
  );

  void dispose() {
    search.dispose();
    model.dispose();
    shell.dispose();
    other.dispose();
    plain.dispose();
  }
}

final _rigs = <_Rig>[];

Future<_Rig> _start(
  WidgetTester tester, {
  Size window = shellWindow,
  GraphShownView? view,
  List<GraphRecent>? recent,
}) async {
  useShellWindow(tester, window);
  final rig = _Rig(view: view ?? GraphShownView.defaultSearch, recent: recent);
  _rigs.add(rig);
  await tester.pumpWidget(rig.host());
  await tester.pump();
  return rig;
}

void _testWidgets(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      for (final _Rig rig in _rigs) {
        rig.dispose();
      }
      _rigs.clear();
    });

Finder _tooltip(String message) => find.byWidgetPredicate((w) => w is ZsTooltip && w.message == message);
Finder _field() => find.descendant(of: find.byType(GraphSearchField), matching: find.byType(TextField));
String _fieldText(WidgetTester tester) => tester.widget<TextField>(_field()).controller!.text;
Finder _pill() => find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == 'graph-search-pill');
List<ZsFieldListRow> _rows(WidgetTester tester) =>
    tester.widgetList<ZsFieldListRow>(find.byType(ZsFieldListRow)).toList();

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_field(), text);
  await tester.pump();
  await tester.pump(_pause);
  await tester.pump();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  setUpIconRegistry();
  tearDown(ZsTooltip.resetWarmWindow);

  group('the field', () {
    _testWidgets('the default search: empty, the placeholder and ⌘F, no ✕', (tester) async {
      await _start(tester);
      expect(_fieldText(tester), isEmpty);
      expect(find.text('Search changes, bookmarks, authors, files…'), findsOneWidget);
      expect(find.text('⌘F'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == 'graph-search-clear'),
        findsNothing,
      );
    });

    _testWidgets('a typed filter: scope label and value, ✕ back to the default search — one request', (tester) async {
      final _Rig rig = await _start(tester, view: GraphFilterView(GraphFilter.author('Lena König')));
      expect(rig.source.requests.single.revset, 'author(exact:"Lena König")');
      expect(_fieldText(tester), 'Lena König');
      expect(find.text('Author'), findsOneWidget);
      expect(_tooltip('Back to the default search — jj log'), findsOneWidget);
      await tester.tap(_tooltip('Back to the default search — jj log'));
      await tester.pump();
      expect(rig.source.requests, hasLength(2));
      expect(rig.source.requests.last.revset, rig.source.defaults.log);
      expect(rig.search.view, GraphShownView.defaultSearch);
    });

    _testWidgets('all(): \$ and all() in the field', (tester) async {
      await _start(tester, view: const GraphAllView());
      expect(find.text(r'$'), findsOneWidget);
      expect(find.text('all()'), findsOneWidget);
    });

    _testWidgets('stale: the field is disabled with the reason', (tester) async {
      final rig = _Rig()..source.respond = (_) => throw staleError('stale');
      _rigs.add(rig);
      useShellWindow(tester);
      await tester.pumpWidget(rig.host());
      await tester.pump();
      expect(rig.model.stale, isNotNull);
      expect(find.ancestor(of: find.byType(GraphSearchField), matching: find.byType(IgnorePointer)), findsWidgets);
      expect(_tooltip(rig.model.stale!.message!), findsOneWidget);
      expect(rig.search.focusField(), isFalse);
    });

    for (final (double width, double input, bool label, bool hint) in <(double, double, bool, bool)>[
      (1181, 320, true, true),
      (1180, 250, true, true),
      (1101, 250, true, true),
      (1100, 250, false, true),
      (981, 250, false, true),
      (980, 170, false, false),
    ]) {
      _testWidgets('at a ${width.toInt()} px window the input is ${input.toInt()}', (tester) async {
        await _start(tester, window: Size(width, 900));
        final double w = tester.getSize(find.ancestor(of: _field(), matching: find.byType(SizedBox)).first).width;
        expect(w, input);
        expect(graphSearchInputWidth(width), input);
        expect(find.text('⌘F'), hint ? findsOneWidget : findsNothing);
        expect(find.text(hint ? 'Search changes, bookmarks, authors, files…' : 'Search…'), findsOneWidget);
        await tester.enterText(_field(), 'a:');
        await tester.pump();
        expect(find.descendant(of: _pill(), matching: find.text('Author')), label ? findsOneWidget : findsNothing);
      });
    }
  });

  group('the menu', () {
    _testWidgets('order, Default tag, the check on what the graph shows; variants send their revset', (tester) async {
      final _Rig rig = await _start(tester);
      await tester.tap(_pill());
      await tester.pump();
      expect(_rows(tester).map((r) => r.identifier), <String>[
        'graph-search-menu-log',
        'graph-search-menu-all',
        'graph-search-menu-change',
        'graph-search-menu-bookmark',
        'graph-search-menu-author',
        'graph-search-menu-file',
        'graph-search-menu-description',
        'graph-search-menu-edit',
      ]);
      expect(find.text('Default'), findsOneWidget);
      expect(_rows(tester).where((r) => r.shown).single.identifier, 'graph-search-menu-log');
      expect(_rows(tester).first.active, isTrue, reason: 'the keyboard row starts on the current row');
      expect(rig.shell.calm.held, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.source.requests.last.revset, 'all()');
      expect(rig.shell.calm.held, isFalse);
      await tester.tap(_pill());
      await tester.pump();
      expect(_rows(tester).where((r) => r.shown).single.identifier, 'graph-search-menu-all');
      await _key(tester, LogicalKeyboardKey.end);
      expect(_rows(tester).where((r) => r.active).single.identifier, 'graph-search-menu-description');
      await _key(tester, LogicalKeyboardKey.home);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.source.requests.last.revset, rig.source.defaults.log);
      expect(rig.source.requests, hasLength(3));
    });

    _testWidgets('Esc closes the menu and restores the field; a scope pick keeps focus in the field', (tester) async {
      final _Rig rig = await _start(tester);
      await tester.tap(_pill());
      await tester.pump();
      await tester.tap(find.text('Bookmark'));
      await tester.pump();
      expect(find.descendant(of: _pill(), matching: find.text('Bookmark')), findsOneWidget);
      expect(tester.widget<TextField>(_field()).focusNode!.hasFocus, isTrue);
      await tester.tap(_pill());
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(ZsFieldListRow), findsNothing);
      expect(rig.shell.calm.held, isFalse);
    });
  });

  group('filters, go-to, Recent', () {
    _testWidgets('a: lena, Enter on Lena König: one request for the footer expression and a recent', (tester) async {
      final _Rig rig = await _start(tester);
      await tester.tap(_field());
      await tester.pump();
      expect(rig.shell.calm.held, isFalse, reason: 'no Recent yet: nothing opens');
      await _type(tester, 'a:');
      expect(find.descendant(of: _pill(), matching: find.text('Author')), findsOneWidget);
      await _type(tester, 'lena');
      expect(find.text('Lena König'), findsOneWidget);
      expect(find.text('''jj log -r 'author(exact:"Lena König")\''''), findsOneWidget);
      final int before = rig.source.requests.length;
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.source.requests, hasLength(before + 1));
      expect(rig.source.requests.last.revset, 'author(exact:"Lena König")');
      expect(rig.store.loadRecent().first, GraphRecentFilter(GraphFilter.author('Lena König')));
      expect(_fieldText(tester), 'Lena König');
    });

    _testWidgets('Backspace in an empty field returns to Any; Esc closes, a second Esc restores and blurs', (
      tester,
    ) async {
      await _start(tester);
      await tester.tap(_field());
      await _type(tester, 'f: ');
      expect(find.descendant(of: _pill(), matching: find.text('File')), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.backspace);
      expect(find.descendant(of: _pill(), matching: find.text('File')), findsNothing);
      await _type(tester, 'xyz');
      expect(find.byType(ZsFieldListRow), findsWidgets);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(ZsFieldListRow), findsNothing);
      expect(_fieldText(tester), 'xyz');
      await _key(tester, LogicalKeyboardKey.escape);
      expect(_fieldText(tester), isEmpty);
      expect(tester.widget<TextField>(_field()).focusNode!.hasFocus, isFalse);
    });

    _testWidgets('a visible go-to target is selected and pulsed, without a request', (tester) async {
      final _Rig rig = await _start(tester);
      await tester.tap(_field());
      await _type(tester, 'c: k2');
      final int before = rig.source.requests.length;
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.source.requests, hasLength(before));
      expect(rig.model.selected, 'k2');
      expect(rig.model.pulse.value?.key, 'k2');
      expect(rig.store.loadRecent().first, const GraphRecentGoTo('k2'));
      expect(_fieldText(tester), isEmpty, reason: 'the field returns to what the graph shows');
    });

    _testWidgets('a hidden one: one request for all(), selected and pulsed when it lands; no re-centre on @', (
      tester,
    ) async {
      final _Rig rig = await _start(tester);
      rig.searchSource.find = (expression, limit) => FoundChanges(
        entries: <FoundChange>[
          if (expression == 'hid1')
            const FoundChange(commitId: 'chid1', changeId: 'hid1', commitPrefixLen: 2, changePrefixLen: 3),
        ],
        truncated: false,
        warnings: const <ZanshinWarning>[],
      );
      await tester.tap(_field());
      await _type(tester, 'c: hid1');
      expect(rig.searchSource.findCalls.map((c) => c.expression), contains('hid1'));
      expect(find.text('not in view'), findsOneWidget);
      final int before = rig.source.requests.length;
      await _key(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(rig.source.requests, hasLength(before + 1));
      expect(rig.source.requests.last.revset, 'all()');
      expect(rig.model.selected, 'hid1');
      expect(rig.model.pulse.value?.key, 'hid1');
      expect(rig.model.reveal?.key, 'hid1');
      expect(rig.search.view, const GraphAllView());
    });

    _testWidgets('an ambiguous prefix is jj\'s refusal row; Enter does nothing', (tester) async {
      final _Rig rig = await _start(tester);
      rig.searchSource.find = (expression, limit) => expression == 'zz'
          ? throw const ZanshinFfiException.withReport(
              'jj.revset_resolution_error',
              'Change ID prefix `zz` is ambiguous',
              precondition: null,
              warnings: <ZanshinWarning>[],
              revsetError: RevsetErrorDetail(
                kind: RevsetErrorKind.ambiguousChangeIdPrefix,
                span: null,
                symbol: 'zz',
                candidates: <String>[],
              ),
            )
          : const FoundChanges(entries: <FoundChange>[], truncated: false, warnings: <ZanshinWarning>[]);
      await tester.tap(_field());
      await _type(tester, 'c: zz');
      expect(find.text('Change ID prefix `zz` is ambiguous'), findsWidgets);
      final int before = rig.source.requests.length;
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.source.requests, hasLength(before));
      expect(rig.model.selected, isNull);
    });

    _testWidgets('Recent: per scope, 6 shown of 10 stored, Clear; a bookmark go-to keeps its name', (tester) async {
      final _Rig rig = await _start(
        tester,
        recent: <GraphRecent>[
          const GraphRecentGoTo('k1', bookmark: 'main'),
          for (var i = 0; i < 8; i++) GraphRecentFilter(GraphFilter.author('A$i')),
          const GraphRecentGoTo('k2'),
        ],
      );
      expect(rig.search.recentFor(GraphSearchScope.any), hasLength(GraphSearchController.shownRecent));
      expect(rig.search.recentFor(GraphSearchScope.bookmark).single, const GraphRecentGoTo('k1', bookmark: 'main'));
      expect(rig.search.recentFor(GraphSearchScope.change).single, const GraphRecentGoTo('k2'));
      expect(rig.search.recentFor(GraphSearchScope.file), isEmpty);
      await tester.tap(_field());
      await tester.pump();
      expect(find.text('RECENT'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(rig.shell.calm.held, isTrue);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(rig.store.loadRecent(), isEmpty);
      expect(tester.widget<TextField>(_field()).focusNode!.hasFocus, isTrue);
      for (var i = 0; i < 12; i++) {
        rig.search.apply(GraphFilter.author('B$i'));
      }
      expect(rig.store.loadRecent(), hasLength(GraphSearchController.maxRecent));
    });
  });

  group('review follow-ups', () {
    _testWidgets('b: ma lists local and remote bookmarks (a null target skipped); Enter keeps the name in Recent', (
      tester,
    ) async {
      final _Rig rig = await _start(tester);
      rig.searchSource
        ..bookmarkList = <Bookmark>[
          localBookmark('main', 'k1'),
          remoteBookmark('main', 'origin', 'k2'),
          localBookmark('mangled', null),
        ]
        ..email = 'lena@x.org';
      await tester.tap(_field());
      await tester.pump();
      await _type(tester, 'b: ma');
      expect(find.text('main'), findsOneWidget);
      expect(find.text('main@origin'), findsOneWidget);
      expect(find.text('mangled'), findsNothing);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.store.loadRecent().first, const GraphRecentGoTo('k1', bookmark: 'main'));
      expect(rig.model.selected, 'k1');
      await tester.tap(_field());
      await tester.pump();
      await _type(tester, 'a: lena');
      expect(find.text('you · mine()'), findsOneWidget);
    });

    _testWidgets('a Recent bookmark go-to goes where the bookmark points now', (tester) async {
      final _Rig rig = await _start(tester, recent: <GraphRecent>[const GraphRecentGoTo('k3', bookmark: 'main')]);
      rig.searchSource.bookmarkList = <Bookmark>[localBookmark('main', 'k1')];
      await tester.tap(_field());
      await tester.pump();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.enter);
      expect(rig.model.selected, 'k1');
    });

    _testWidgets('Recent hides a go-to absent from a shown all() layout; re-applying a filter moves it to the front', (
      tester,
    ) async {
      final _Rig rig = await _start(
        tester,
        view: const GraphAllView(),
        recent: <GraphRecent>[const GraphRecentGoTo('gone'), const GraphRecentGoTo('k2')],
      );
      expect(rig.search.recentFor(GraphSearchScope.any), <GraphRecent>[const GraphRecentGoTo('k2')]);
      final a = GraphFilter.author('A');
      rig.search
        ..apply(a)
        ..apply(GraphFilter.author('B'))
        ..apply(a);
      final List<GraphRecent> recent = rig.store.loadRecent();
      expect(recent.first, GraphRecentFilter(a));
      expect(recent.where((r) => r == GraphRecentFilter(a)), hasLength(1));
    });

    _testWidgets('after a layout at a new operation, typing asks counts, finds and bookmarks again there', (
      tester,
    ) async {
      final _Rig rig = await _start(tester);
      await tester.tap(_field());
      await tester.pump();
      await _type(tester, 'lena');
      expect(rig.searchSource.countCalls.last.operationId, 'op1');
      expect(rig.searchSource.findCalls.last.operationId, 'op1');
      final int reads = rig.searchSource.bookmarkReads;
      rig.respond = (request) => _layout(op: 'op2');
      rig.source.respond = rig.respond;
      rig.model.reload();
      await tester.pump();
      await _type(tester, 'lenax');
      await _type(tester, 'lena');
      expect(rig.searchSource.countCalls.last.operationId, 'op2');
      expect(rig.searchSource.countCalls.last.expressions, contains('author(exact:"Lena König")'));
      expect(rig.searchSource.findCalls.last.operationId, 'op2');
      expect(rig.searchSource.bookmarkReads, greaterThan(reads));
    });
  });

  test('a stored non-default view reaches the first request through GraphPreferences', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zanshin_graph_search_prefs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore settings = await SettingsStore.load(File('${dir.path}/settings.json'));
    final source = ScriptedGraphSource();
    final model = GraphViewModel();
    final search = GraphSearchController(
      model: model,
      source: FakeGraphSearchSource(),
      store: MemoryGraphSearchStore(view: const GraphAllView()),
    );
    final preferences = GraphPreferences(settings)..init(model, source, revset: search.revset);
    await Future<void>.delayed(Duration.zero);
    expect(source.requests.first.revset, 'all()');
    preferences.dispose();
    search.dispose();
    model.dispose();
  });

  group('counts', () {
    _testWidgets('requested once per (operation, expression) after the pause; a zero count dims its row', (
      tester,
    ) async {
      final _Rig rig = await _start(tester);
      rig.searchSource.count = (e) =>
          RevsetCount(n: e.startsWith('author') ? 0 : 12000, capped: !e.startsWith('author'), error: null);
      await tester.tap(_field());
      await tester.enterText(_field(), 'lena');
      await tester.pump();
      expect(rig.searchSource.countCalls, isEmpty, reason: 'rows render before their counts');
      expect(find.text('Lena König'), findsOneWidget);
      await tester.pump(_pause);
      await tester.pump();
      expect(rig.searchSource.countCalls.single.operationId, 'op1');
      expect(rig.searchSource.countCalls.single.expressions, <String>[
        'author(exact:"Lena König")',
        'description(substring-i:"lena")',
      ]);
      expect(find.text('10,000+ changes'), findsOneWidget);
      expect(find.ancestor(of: find.text('Lena König'), matching: find.byType(Opacity)), findsWidgets);
      await _type(tester, 'lenax');
      await _type(tester, 'lena');
      expect(
        rig.searchSource.countCalls.expand((c) => c.expressions).where((e) => e.startsWith('author')),
        hasLength(1),
      );
    });

    _testWidgets('a File row is counted only as the keyboard row', (tester) async {
      final _Rig rig = await _start(tester);
      rig.searchSource.paths = <String>['lib/cache.dart'];
      await tester.tap(_field());
      await tester.pump();
      await _type(tester, 'f: lib');
      List<String> counted() => rig.searchSource.countCalls.expand((c) => c.expressions).toList();
      expect(counted(), <String>['files(cwd:"lib/")']);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(_pause);
      await tester.pump();
      expect(counted(), <String>['files(cwd:"lib/")', 'files(file:"lib/cache.dart")']);
    });
  });

  _testWidgets('a revset error: jj\'s message in the footer, the span underlined at UTF-16 offsets', (tester) async {
    final _Rig rig = await _start(tester);
    rig.source.respond = (request) => request.revset.startsWith('author')
        ? throw const ZanshinFfiException.withReport(
            'jj.revset_parse_error',
            'Failed to parse revset',
            precondition: null,
            warnings: <ZanshinWarning>[],
            // `König"` from byte 19 ("ö" is two bytes), 7 bytes long.
            revsetError: RevsetErrorDetail(
              kind: RevsetErrorKind.syntaxError,
              span: RevsetSpan(offset: 19, length: 7),
              symbol: null,
              candidates: <String>[],
            ),
          )
        : _layout();
    rig.search.apply(GraphFilter.author('Lena König'));
    await tester.pump();
    expect(rig.model.revsetError, isNotNull);
    expect(rig.model.layout, isNotNull, reason: 'the graph keeps its last layout');
    await tester.tap(_field());
    await tester.pump();
    expect(find.text('Failed to parse revset'), findsOneWidget);
    final RichText span = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('graph-search-error-span')),
        matching: find.byType(RichText),
      ),
    );
    final underlined = <String>[];
    span.text.visitChildren((s) {
      if (s is TextSpan && s.style?.decoration == TextDecoration.underline) {
        underlined.add(s.text!);
      }
      return true;
    });
    expect(underlined, <String>['König"']);
  });

  group('shortcuts', () {
    _testWidgets('⌘F focuses the field with its text selected', (tester) async {
      final _Rig rig = await _start(tester, view: GraphFilterView(GraphFilter.author('Lena König')));
      rig.plain.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      final TextField field = tester.widget<TextField>(_field());
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 10));
    });

    _testWidgets('/ outside a text field focuses the field; inside one it does not', (tester) async {
      final _Rig rig = await _start(tester);
      await tester.tap(find.byType(ZsTextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pump();
      expect(tester.widget<TextField>(_field()).focusNode!.hasFocus, isFalse);
      rig.plain.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pump();
      expect(tester.widget<TextField>(_field()).focusNode!.hasFocus, isTrue);
    });
  });

  test('ProjectSearchStore keeps the view and Recent on the registry entry, per repository', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zanshin_graph_search');
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore settings = await SettingsStore.load(File('${dir.path}/settings.json'));
    await settings.update(
      (s) => s.copyWith(
        projects: const ProjectsSettings(
          projects: <ProjectEntry>[
            ProjectEntry(path: '/a', name: 'a'),
            ProjectEntry(path: '/b', name: 'b'),
          ],
        ),
      ),
    );
    final a = ProjectSearchStore(settings, '/a');
    final b = ProjectSearchStore(settings, '/b');
    a
      ..saveView(const GraphAllView())
      ..saveRecent(<GraphRecent>[const GraphRecentGoTo('kx', bookmark: 'main')]);
    expect(a.loadView(), const GraphAllView());
    expect(a.loadRecent(), <GraphRecent>[const GraphRecentGoTo('kx', bookmark: 'main')]);
    expect(b.loadView(), GraphShownView.defaultSearch);
    expect(b.loadRecent(), isEmpty);
    final outside = ProjectSearchStore(settings, '/c')..saveView(const GraphAllView());
    expect(outside.loadView(), const GraphAllView());
    expect(settings.value.projects.projects.map((p) => p.path), <String>['/a', '/b']);
    unawaited(Future<void>.value());
  });
}
