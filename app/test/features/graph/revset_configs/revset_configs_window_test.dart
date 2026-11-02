// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart';
import 'package:zanshin/src/features/shell/app_menu.dart' show GraphMenuBinding;
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../helpers/fake_graph_search_source.dart';
import '../../../helpers/icon_registry.dart';
import '../../../helpers/scripted_graph_source.dart';
import '../../../helpers/shell_host.dart';
import '../graph_harness.dart';

const _mine = RevsetConfiguration(
  id: 'c1',
  name: 'Mine',
  rules: <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.mine)],
);
const _lena = RevsetConfiguration(
  id: 'c2',
  name: 'Lena',
  rules: <RevsetRule>[
    RevsetRule(fn: RevsetRuleFunction.description, value: 'fix'),
    RevsetRule(fn: RevsetRuleFunction.author, value: 'lena'),
  ],
);

/// Windows that record what the window asks of them; the close handler is the red button's.
class _Windows extends AppWindows {
  _Windows() : super(exitProcess: () async {});

  final closed = <String>[];
  final activated = <String>[];
  Future<void> Function()? redButton;

  @override
  void close(String key) => closed.add(key);

  @override
  void activate(String key) => activated.add(key);

  @override
  void setCloseHandler(String key, Future<void> Function()? handler) {
    redButton = handler;
    super.setCloseHandler(key, handler);
  }
}

class _Rig {
  late final SettingsStore store;
  late final File file;
  final windows = _Windows();
  final searchSource = FakeGraphSearchSource()..email = 'lena@example.org';
  // Pinned to an operation, as a worker layout is: counts and reads are per operation.
  final source = ScriptedGraphSource(
    respond: (_) => handLayout(
      const <(String, int, int)>[('a', 2, 0), ('b', 1, 0), ('c', 0, 0)],
      edges: const <(int, int)>[(0, 1), (1, 2)],
      workingCopy: 0,
      operationId: 'op1',
      totalCount: 3,
    ),
  );
  final model = GraphViewModel();
  final graph = ValueNotifier<GraphMenuBinding?>(null);
  final urls = <Uri>[];
  late final GraphSearchController search;
  late final GraphPreferences preferences;
  final key = GlobalKey<RevsetConfigsWindowState>();

  Future<void> setUp(
    WidgetTester tester, {
    GraphShownView view = GraphShownView.defaultSearch,
    bool project = true,
    String home = revsetDefaultLog,
  }) async {
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('revset_configs_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    file = File('${dir.path}/settings.json');
    store = (await tester.runAsync(() async {
      final SettingsStore store = await SettingsStore.load(file);
      await store.update(
        (s) => s.copyWith(
          graph: GraphSettings(revsetConfigs: const <RevsetConfiguration>[_mine, _lena], revsetDefault: home),
        ),
      );
      return store;
    }))!;
    search = GraphSearchController(
      model: model,
      source: searchSource,
      store: MemoryGraphSearchStore(view: view),
      settings: store,
      pause: Duration.zero,
    );
    preferences = GraphPreferences(store);
    model.init(source, revset: search.revset);
    if (project) {
      graph.value = GraphMenuBinding(model: model, preferences: preferences, search: search);
    }
    await tester.pumpWidget(
      shellHost(
        Center(
          child: SizedBox(
            width: 880,
            height: 580,
            child: RevsetConfigsWindow(
              key: key,
              settings: store,
              graph: graph,
              windows: windows,
              openUrl: (url) async => urls.add(url),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// Unmounts the window and disposes the graph (its minute tick is a timer).
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    search.dispose();
    preferences.dispose();
    model.dispose();
    graph.dispose();
  }

  /// Lets the counts' batch run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  RevsetConfigsWindowState get state => key.currentState!;

  Future<void> tap(WidgetTester tester, String identifier) async {
    await tester.ensureVisible(find.bySemanticsIdentifier(identifier));
    await tester.pump();
    await tester.tap(find.bySemanticsIdentifier(identifier));
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String identifier, String text) async {
    await tester.enterText(
      find.descendant(of: find.bySemanticsIdentifier(identifier), matching: find.byType(EditableText)),
      text,
    );
    await settle(tester);
  }

  /// The control [identifier].
  T control<T extends Widget>(WidgetTester tester, String identifier) => tester.widget<T>(
    find.byWidgetPredicate(
      (w) => switch (w) {
        final ZsControl c => c.identifier == identifier,
        _ => false,
      },
    ),
  );

  bool enabled(WidgetTester tester, String identifier) => switch (control<Widget>(tester, identifier)) {
    final ZsButton b => b.onPressed != null,
    final ZsSwitch s => s.onChanged != null,
    final Widget w => throw StateError('no enablement for $w'),
  };

  /// [file] reloaded once the store's write chain (real file IO) has landed the in-memory graph settings — polled,
  /// since a fixed wait loses under a loaded test run.
  Future<SettingsStore> reloadSaved(WidgetTester tester) async {
    for (var i = 0; ; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      final SettingsStore reloaded = (await tester.runAsync(() => SettingsStore.load(file)))!;
      if (reloaded.value.graph == store.value.graph || i >= 500) {
        return reloaded;
      }
    }
  }
}

/// A widget test over a fresh [_Rig], which it tears down after [body].
void _testWindow(String description, Future<void> Function(WidgetTester tester, _Rig rig) body) =>
    testWidgets(description, (tester) async {
      final rig = _Rig();
      await body(tester, rig);
      await rig.done(tester);
    });

void main() {
  setUpIconRegistry();

  _testWindow('the shown entry is selected; the preview shows the command, "N of M" from the op-pinned count and '
      'Copy copies the shell-quoted command', (tester, rig) async {
    rig.searchSource.count = (e) => RevsetCount(
      n: e == 'description(substring:"fix") & author(substring:"lena")' ? 2 : 0,
      capped: false,
      error: null,
    );
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    expect(rig.state.draft.selected, 'c2');
    const command = "jj log -r 'description(substring:\"fix\") & author(substring:\"lena\")'";
    expect(find.textContaining(command), findsOneWidget);
    expect(find.textContaining('2 of 3 changes match'), findsOneWidget);

    await rig.tap(tester, 'revset-configs-copy');
    expect(copied, command);
    expect(find.text('Copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('Copy'), findsOneWidget);
  });

  _testWindow('a count error names jj\'s message and marks the rule whose term holds its span', (tester, rig) async {
    // The span sits inside rule 2's term: `author(…)` after `description(substring:"fix") & `.
    const prefix = 'description(substring:"fix") & ';
    rig.searchSource.count = (e) => const RevsetCount(
      n: 0,
      capped: false,
      error: ZanshinFfiException.withReport(
        'jj.revset_resolution_error',
        'No such author',
        precondition: null,
        warnings: <ZanshinWarning>[],
        revsetError: RevsetErrorDetail(
          kind: RevsetErrorKind.expression,
          span: RevsetSpan(offset: prefix.length + 2, length: 3),
          symbol: null,
          candidates: <String>[],
        ),
      ),
    );
    await rig.setUp(tester, view: const GraphConfigView('c2'));

    expect(find.text('No such author'), findsOneWidget);
    expect(
      <bool>[
        for (final int i in <int>[0, 1]) rig.control<ZsTextField>(tester, 'revset-configs-rule-$i-value').error != null,
      ],
      <bool>[false, true],
    );
    expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-1-value').error, '', reason: 'mark only');
  });

  _testWindow(
    'Story 10.28: the revset chip adds a raw rule with no mode and no Aa; alone its text is the -r verbatim',
    (
      tester,
      rig,
    ) async {
      await rig.setUp(tester, view: const GraphConfigView('c1'));
      await rig.tap(tester, 'revset-configs-rule-0-remove');
      await rig.tap(tester, 'revset-configs-add-revset');
      expect(rig.state.draft.current!.rules.single.fn, RevsetRuleFunction.revset);
      expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-0-value').placeholder, 'trunk()..@');
      await rig.type(tester, 'revset-configs-rule-0-value', 'trunk()..@');

      expect(find.textContaining("❯ jj log -r 'trunk()..@'"), findsOneWidget);
      expect(find.bySemanticsIdentifier('revset-configs-rule-0-mode'), findsNothing);
      expect(find.bySemanticsIdentifier('revset-configs-rule-0-ci'), findsNothing);
    },
  );

  _testWindow('Story 10.28: a raw rule joined with an author rule is grouped inside the shell-quoted -r', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    rig.state.draft.setRule(0, const RevsetRule(fn: RevsetRuleFunction.revset, value: 'trunk()..@'));
    await rig.settle(tester);
    expect(find.textContaining("jj log -r '(trunk()..@) & author(substring:\"lena\")'"), findsOneWidget);
  });

  _testWindow("Story 10.28: a count error inside a raw rule's term shows jj's text and its candidates at that row", (
    tester,
    rig,
  ) async {
    rig.searchSource.count = (e) => const RevsetCount(
      n: 0,
      capped: false,
      error: ZanshinFfiException.withReport(
        'jj.revset_parse_error',
        'Function `trunkk` doesn\'t exist',
        precondition: null,
        warnings: <ZanshinWarning>[],
        revsetError: RevsetErrorDetail(
          kind: RevsetErrorKind.noSuchFunction,
          // Inside `(trunkk())`, the joined raw term.
          span: RevsetSpan(offset: 1, length: 6),
          symbol: 'trunkk',
          candidates: <String>['trunk'],
        ),
      ),
    );
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    rig.state.draft.setRule(0, const RevsetRule(fn: RevsetRuleFunction.revset, value: 'trunkk()'));
    await rig.settle(tester);

    expect(
      rig.control<ZsTextField>(tester, 'revset-configs-rule-0-value').error,
      "Function `trunkk` doesn't exist\nDid you mean `trunk`?",
    );
    expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-1-value').error, isNull);
  });

  _testWindow("a mine() row reads the project's user.email", (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c1'));
    expect(find.textContaining('lena@example.org'), findsOneWidget);
    expect(find.textContaining('user.email'), findsOneWidget);
  });

  _testWindow('Apply is disabled until an edit (the default alone counts); Apply on the shown configuration saves '
      'and sends exactly one layout request', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    expect(rig.enabled(tester, 'revset-configs-apply'), isFalse);

    await rig.tap(tester, 'revset-configs-default');
    expect(rig.state.draft.home, 'c2');
    expect(rig.enabled(tester, 'revset-configs-apply'), isTrue);
    await rig.tap(tester, 'revset-configs-default');
    expect(rig.enabled(tester, 'revset-configs-apply'), isFalse, reason: 'back to what is stored');

    final int before = rig.source.requests.length;
    await rig.type(tester, 'revset-configs-rule-1-value', 'ralph');
    expect(rig.enabled(tester, 'revset-configs-apply'), isTrue);
    await rig.tap(tester, 'revset-configs-apply');
    expect(rig.store.value.graph.revsetConfigs[1].rules[1].value, 'ralph');
    expect(rig.source.requests.length - before, 1);
    expect(rig.source.requests.last.revset, 'description(substring:"fix") & author(substring:"ralph")');
    expect(rig.enabled(tester, 'revset-configs-apply'), isFalse);
    expect(rig.windows.closed, isEmpty, reason: 'Apply keeps the window');
  });

  _testWindow('OK saves, shows the selected entry in one request and closes; the default shows as the default '
      'search', (tester, rig) async {
    await rig.setUp(tester);
    final int before = rig.source.requests.length;
    await rig.tap(tester, 'revset-configs-item-c1');
    await rig.tap(tester, 'revset-configs-rule-0-not');
    await rig.tap(tester, 'revset-configs-ok');
    expect(rig.source.requests.length - before, 1);
    expect(rig.source.requests.last.revset, '~mine()');
    expect(rig.search.view, const GraphConfigView('c1'));
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
    expect(rig.store.value.graph.revsetConfigs.first.rules.single.not, isTrue);
  });

  _testWindow('OK on the default entry shows the default search', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c1'), home: 'c2');
    await rig.tap(tester, 'revset-configs-item-c2');
    await rig.tap(tester, 'revset-configs-ok');
    expect(rig.search.view, GraphShownView.defaultSearch);
    expect(rig.source.requests.last.revset, 'description(substring:"fix") & author(substring:"lena")');
  });

  _testWindow('the list toolbar adds, duplicates, moves and removes; removing the default falls back to jj log and '
      'the shown one to the default search', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'), home: 'c2');
    List<String> names() => <String>[for (final RevsetConfiguration c in rig.state.draft.configs) c.name];

    await rig.tap(tester, 'revset-configs-add');
    expect(names(), <String>['Mine', 'Lena', 'New configuration']);
    expect(rig.state.draft.current!.rules.single.fn, RevsetRuleFunction.files);
    await rig.tap(tester, 'revset-configs-up');
    expect(names(), <String>['Mine', 'New configuration', 'Lena']);
    await rig.tap(tester, 'revset-configs-duplicate');
    expect(names(), <String>['Mine', 'New configuration', 'New configuration copy', 'Lena']);
    await rig.tap(tester, 'revset-configs-down');
    expect(names(), <String>['Mine', 'New configuration', 'Lena', 'New configuration copy']);

    await rig.tap(tester, 'revset-configs-item-c2');
    await rig.tap(tester, 'revset-configs-remove');
    expect(rig.state.draft.home, revsetDefaultLog);
    await rig.tap(tester, 'revset-configs-apply');
    expect(rig.store.value.graph.effectiveRevsetDefault, revsetDefaultLog);
    expect(rig.search.view, GraphShownView.defaultSearch);
    expect(rig.source.requests.last.revset, 'L');
    expect(
      <String>[for (final c in rig.store.value.graph.revsetConfigs) c.name],
      <String>[
        'Mine',
        'New configuration',
        'New configuration copy',
      ],
    );
  });

  _testWindow("jj log's switch is locked on while it is the default; the built-ins are read-only", (tester, rig) async {
    await rig.setUp(tester);
    expect(rig.state.draft.selected, revsetDefaultLog);
    expect(rig.enabled(tester, 'revset-configs-default'), isFalse);
    expect(find.text('Used whenever no other configuration is the default'), findsOneWidget);
    expect(find.bySemanticsIdentifier('revset-configs-name'), findsNothing);
    expect(find.textContaining('Built-in · '), findsOneWidget);
  });

  _testWindow('a clean Esc closes without asking; a dirty Esc, ⌘W or red button asks "Discard changes?": Cancel '
      'keeps the window and the edits, Discard drops them and closes', (tester, rig) async {
    await rig.setUp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await rig.settle(tester);
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
    expect(find.text('Discard changes?'), findsNothing);
    rig.windows.closed.clear();

    await rig.tap(tester, 'revset-configs-item-c1');
    await rig.tap(tester, 'revset-configs-default');
    unawaited(rig.windows.redButton!());
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(rig.windows.closed, isEmpty);
    expect(rig.state.draft.dirty, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
    expect(rig.state.draft.dirty, isFalse);
    expect(rig.store.value.graph.revsetDefault, revsetDefaultLog, reason: 'nothing was saved');
  });

  _testWindow('while dirty a close guard asks (project close, ⌘Q, switch): Cancel refuses, Discard lets it on; '
      'clean, it asks nothing', (tester, rig) async {
    await rig.setUp(tester);
    expect(await rig.windows.mayClose(), isTrue);

    await rig.tap(tester, 'revset-configs-add');
    final Future<bool> refused = rig.windows.mayClose();
    await tester.pumpAndSettle();
    expect(rig.windows.activated, <String>[revsetConfigsWindowKey], reason: 'the window comes forward');
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(await refused, isFalse);
    expect(rig.state.draft.dirty, isTrue);

    final Future<bool> allowed = rig.windows.mayClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(await allowed, isTrue);
    expect(rig.state.draft.dirty, isFalse);
    expect(await rig.windows.mayClose(), isTrue, reason: 'clean again: the guard is gone');
  });

  _testWindow('without a project the preview has no count and OK only saves; Revset reference opens jj\'s page', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester, project: false);
    await rig.tap(tester, 'revset-configs-item-c1');
    expect(find.textContaining('changes match'), findsNothing);
    await rig.tap(tester, 'revset-configs-reference');
    expect(rig.urls, <Uri>[Uri.parse('https://docs.jj-vcs.dev/v0.46.0/revsets/')]);
    await rig.tap(tester, 'revset-configs-default');
    await rig.tap(tester, 'revset-configs-ok');
    expect(rig.store.value.graph.revsetDefault, 'c1');
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
  });

  _testWindow('saved configurations and the default survive a restart and read the same in a second repository', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester);
    await rig.tap(tester, 'revset-configs-item-c1');
    await rig.tap(tester, 'revset-configs-default');
    await rig.tap(tester, 'revset-configs-ok');
    final SettingsStore reloaded = await rig.reloadSaved(tester);
    expect(reloaded.value.graph.revsetConfigs, rig.store.value.graph.revsetConfigs);
    expect(reloaded.value.graph.revsetDefault, 'c1');

    final second = GraphViewModel();
    final other = GraphSearchController(
      model: second,
      source: FakeGraphSearchSource(),
      store: ProjectSearchStore(reloaded, '/r/other'),
      settings: reloaded,
    );
    addTearDown(() {
      other.dispose();
      second.dispose();
    });
    expect(other.defaultSearch, 'c1');
    expect(other.revset, 'mine()');
  });

  RevsetCount countError(String code, String context, RevsetErrorKind kind, RevsetSpan? span, String? symbol) =>
      RevsetCount(
        n: 0,
        capped: false,
        error: ZanshinFfiException.withReport(
          code,
          context,
          precondition: null,
          warnings: const <ZanshinWarning>[],
          revsetError: RevsetErrorDetail(kind: kind, span: span, symbol: symbol, candidates: const <String>[]),
        ),
      );

  _testWindow("Story 10.28: a spanless resolution error reaches the raw rule naming its symbol, jj's text only", (
    tester,
    rig,
  ) async {
    rig.searchSource.count = (_) => countError(
      'jj.revset_resolution_error',
      'Revision `nosuch` doesn\'t exist',
      RevsetErrorKind.noSuchRevision,
      null,
      'nosuch',
    );
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    rig.state.draft.setRule(0, const RevsetRule(fn: RevsetRuleFunction.revset, value: 'trunk()..nosuch'));
    await rig.settle(tester);

    expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-0-value').error, "Revision `nosuch` doesn't exist");
    expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-1-value').error, isNull);
  });

  _testWindow('Story 10.28: an end-of-input parse error marks an alone raw rule', (tester, rig) async {
    rig.searchSource.count = (_) => countError(
      'jj.revset_parse_error',
      'Syntax error',
      RevsetErrorKind.syntaxError,
      const RevsetSpan(offset: 4, length: 0),
      null,
    );
    await rig.setUp(tester, view: const GraphConfigView('c1'));
    rig.state.draft.setRule(0, const RevsetRule(fn: RevsetRuleFunction.revset, value: 'foo('));
    await rig.settle(tester);

    expect(rig.control<ZsTextField>(tester, 'revset-configs-rule-0-value').error, 'Syntax error');
  });

  _testWindow('Story 10.28: the function select labels revset without parentheses', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    final labels = <RevsetRuleFunction, String>{
      for (final ZsSelectEntry<RevsetRuleFunction> e
          in rig.control<ZsSelect<RevsetRuleFunction>>(tester, 'revset-configs-rule-0-fn').options)
        if (e case final ZsSelectOption<RevsetRuleFunction> o) o.value: o.label,
    };
    expect(labels[RevsetRuleFunction.revset], 'revset');
    expect(labels[RevsetRuleFunction.author], 'author()');
  });

  _testWindow('Story 10.28: a saved raw rule reads back after a reload and searches with its raw expression', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester, view: const GraphConfigView('c1'));
    rig.state.draft.setRule(0, const RevsetRule(fn: RevsetRuleFunction.revset, value: 'conflicts()', not: true));
    await rig.settle(tester);
    await rig.tap(tester, 'revset-configs-default');
    await rig.tap(tester, 'revset-configs-ok');
    final SettingsStore reloaded = await rig.reloadSaved(tester);
    expect(
      reloaded.value.graph.revsetConfigs.first.rules.single,
      const RevsetRule(fn: RevsetRuleFunction.revset, value: 'conflicts()', not: true),
    );
    final second = GraphViewModel();
    final other = GraphSearchController(
      model: second,
      source: FakeGraphSearchSource(),
      store: ProjectSearchStore(reloaded, '/r/other'),
      settings: reloaded,
    );
    addTearDown(() {
      other.dispose();
      second.dispose();
    });
    expect(other.revset, '~(conflicts())');
  });

  String valueOf(WidgetTester tester, String identifier) => tester
      .widget<EditableText>(
        find.descendant(of: find.bySemanticsIdentifier(identifier), matching: find.byType(EditableText)),
      )
      .controller
      .text;

  _testWindow('a value field follows the draft: a function round trip clears it, a Discard restores it', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    expect(valueOf(tester, 'revset-configs-rule-1-value'), 'lena');
    rig.state.draft
      ..setRuleFunction(1, RevsetRuleFunction.mine)
      ..setRuleFunction(1, RevsetRuleFunction.author);
    await rig.settle(tester);
    expect(rig.state.draft.current!.rules[1].value, '');
    expect(valueOf(tester, 'revset-configs-rule-1-value'), '');

    final Future<bool> discarded = rig.windows.mayClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(await discarded, isTrue);
    expect(valueOf(tester, 'revset-configs-rule-1-value'), 'lena');
  });

  _testWindow('focus starts on the selected entry; Tab reaches the next one, Space selects it, ↩ there runs OK', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester);
    Element focused() => FocusManager.instance.primaryFocus!.context! as Element;
    bool inEntry(String identifier) =>
        find.bySemanticsIdentifier(identifier).evaluate().any((e) => focused().debugGetDiagnosticChain().contains(e));
    expect(inEntry('revset-configs-item-log'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(inEntry('revset-configs-item-all'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(rig.state.draft.selected, revsetDefaultAll);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(inEntry('revset-configs-item-c1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await rig.settle(tester);
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey], reason: '↩ on an entry is OK, not a selection');
    expect(rig.search.view, const GraphAllView(), reason: 'OK shows the selected entry, not the focused one');
  });

  _testWindow('a click on another entry, then ↩: OK shows the clicked entry (the focus stayed where it was)', (
    tester,
    rig,
  ) async {
    await rig.setUp(tester);
    await rig.tap(tester, 'revset-configs-item-c2');
    expect(rig.state.draft.selected, 'c2');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await rig.settle(tester);
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
    expect(rig.search.view, const GraphConfigView('c2'));
  });

  _testWindow('↩ outside a text field runs OK: one request, the window closes', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    final int before = rig.source.requests.length;
    // Focus on the window itself, outside any field or entry.
    tester
        .widget<Focus>(
          find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'jj log Configurations'),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await rig.settle(tester);
    expect(rig.source.requests.length - before, 1);
    expect(rig.windows.closed, <String>[revsetConfigsWindowKey]);
  });

  _testWindow('a dirty draft survives a project switch; the count follows the new project', (tester, rig) async {
    rig.searchSource.count = (_) => const RevsetCount(n: 2, capped: false, error: null);
    await rig.setUp(tester, view: const GraphConfigView('c2'));
    expect(find.textContaining('2 of 3 changes match'), findsOneWidget);
    await rig.tap(tester, 'revset-configs-default');
    expect(rig.state.draft.dirty, isTrue);

    final otherSource = ScriptedGraphSource(
      respond: (_) => handLayout(
        const <(String, int, int)>[('x', 1, 0), ('y', 0, 0)],
        edges: const <(int, int)>[(0, 1)],
        workingCopy: 0,
        operationId: 'op9',
        totalCount: 7,
      ),
    );
    final otherModel = GraphViewModel();
    final otherSearch = GraphSearchController(
      model: otherModel,
      source: FakeGraphSearchSource()..count = (_) => const RevsetCount(n: 5, capped: false, error: null),
      store: MemoryGraphSearchStore(),
      settings: rig.store,
      pause: Duration.zero,
    );
    final otherPreferences = GraphPreferences(rig.store);
    otherModel.init(otherSource, revset: otherSearch.revset);
    rig.graph.value = GraphMenuBinding(model: otherModel, preferences: otherPreferences, search: otherSearch);
    await rig.settle(tester);

    expect(rig.state.draft.dirty, isTrue);
    expect(rig.state.draft.selected, 'c2');
    expect(rig.state.draft.home, 'c2');
    expect(find.textContaining('5 of 7 changes match'), findsOneWidget);

    rig.graph.value = null;
    await tester.pump();
    otherSearch.dispose();
    otherPreferences.dispose();
    otherModel.dispose();
  });

  _testWindow('an unnamed configuration duplicates as "Unnamed copy"', (tester, rig) async {
    await rig.setUp(tester, view: const GraphConfigView('c1'));
    rig.state.draft.edit((c) => c.copyWith(name: ''));
    await rig.settle(tester);
    await rig.tap(tester, 'revset-configs-duplicate');
    expect(rig.state.draft.current!.name, 'Unnamed copy');
  });
}
