// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_windows.dart';
import '../../helpers/scripted_graph_source.dart';

const _wc = 'wwwwwwwwyyyyyyyy';
const _mid = 'kmnvxoqpzzzzzzzz';
const _base = 'pppppppprrrrrrrr';

/// A session that counts its refreshes and records its opens instead of opening.
class _Session extends ProjectSession {
  _Session(ProjectRegistry registry) : super(registry: registry, repos: FakeProjectRepos());

  var refreshes = 0;
  final opens = <String>[];

  @override
  void refresh() => refreshes++;

  @override
  Future<ProjectOpenOutcome> open(String path, {String? group, int? index}) async {
    opens.add(path);
    return const ProjectOpened();
  }
}

class _WindowActions implements AppWindowActions {
  var projects = 0;

  @override
  Future<void> openProjects() async => projects++;
}

/// Each run writes operation `op<n>`, the head following.
class _GraphActions implements GraphActions {
  final ran = <GraphAction>[];
  var head = 'op0';

  /// While set, a run waits for it (the runner stays busy).
  Completer<void>? gate;

  @override
  Future<String> headOpId() async => head;

  @override
  Future<MutationResult> run(GraphAction action) async {
    await gate?.future;
    ran.add(action);
    head = 'op${ran.length}';
    return MutationResult(
      newOpId: head,
      newChangeIds: const <String>[],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}

/// A window's stand-in content: a sheet while [sheet] says so, and a text field when [field] is given.
Widget _content(ValueNotifier<bool> sheet, {FocusNode? field, TextEditingController? text}) => Directionality(
  textDirection: TextDirection.ltr,
  child: ValueListenableBuilder<bool>(
    valueListenable: sheet,
    builder: (context, show, _) =>
        // The test window's view is unbounded; the sheet fills its parent.
        SizedBox(
          width: 400,
          height: 300,
          child: Stack(
            children: <Widget>[
              if (field != null)
                EditableText(
                  controller: text!,
                  focusNode: field,
                  style: const TextStyle(),
                  cursorColor: const Color(0xFF000000),
                  backgroundCursorColor: const Color(0xFF000000),
                ),
              if (show) ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: const SizedBox()),
            ],
          ),
        ),
  ),
);

/// Records what [PlatformMenuBar] hands the platform, instead of the channel.
class _MenuDelegate extends PlatformMenuDelegate {
  final sets = <List<PlatformMenuItem>>[];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => sets.add(topLevelMenus);

  @override
  void clearMenus() {}

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

/// Every item of [items], menus and groups included, depth first.
Iterable<PlatformMenuItem> _all(List<PlatformMenuItem> items) sync* {
  for (final item in items) {
    yield item;
    if (item is PlatformMenu) {
      yield* _all(item.menus);
    } else if (item is PlatformMenuItemGroup) {
      yield* _all(item.members);
    }
  }
}

/// The plain items' labels of the top menu [menu], in order.
List<String> _labels(List<PlatformMenuItem> menus, String menu) => <String>[
  for (final PlatformMenuItem item in _all(
    (menus.firstWhere((m) => (m as PlatformMenu).label == menu) as PlatformMenu).menus,
  ))
    if (item is! PlatformMenuItemGroup && item is! PlatformProvidedMenuItem) item.label,
];

class _Rig {
  late final SettingsStore store;
  late final _Session session;
  late final AppWindows windows;
  late final ActiveWindowTracker tracker;
  late final AppMenuModel menu;
  final factory = FakeWindowFactory();
  final actions = _WindowActions();
  final mainSheet = ValueNotifier<bool>(false);
  final projectsSheet = ValueNotifier<bool>(false);
  final closes = <String>[];
  final urls = <Uri>[];
  GraphViewModel? model;
  GraphPreferences? preferences;
  ScriptedGraphSource? source;
  _GraphActions? graphActions;
  var searches = 0;

  /// The text field in the project window.
  final field = FocusNode(debugLabel: 'field');
  final text = TextEditingController(text: 'abc');

  /// The menu bar's delegate, when [setUp] mounts the [AppMenuBar].
  _MenuDelegate? delegate;

  Future<void> setUp(
    WidgetTester tester, {
    List<ProjectEntry> projects = const <ProjectEntry>[],
    bool menuBar = false,
  }) async {
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('app_menu_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    store = (await tester.runAsync(() async {
      final SettingsStore store = await SettingsStore.load(File('${dir.path}/settings.json'));
      await store.update((s) => s.copyWith(projects: ProjectsSettings(projects: projects)));
      return store;
    }))!;
    session = _Session(ProjectRegistry(store));
    addTearDown(session.dispose);
    windows = AppWindows(createController: factory.call, exitProcess: () async {});
    tracker = ActiveWindowTracker();
    menu = AppMenuModel(tracker, session)
      ..attach(windows, actions)
      ..openUrl = (url) async => urls.add(url);
    addTearDown(() {
      menu.dispose();
      tracker.dispose();
      field.dispose();
      text.dispose();
      for (final key in <String>[mainWindowKey, projectsWindowKey]) {
        windows.controllerOf(key)?.destroy();
      }
    });
    final WindowEntry main = await windows.create(
      key: mainWindowKey,
      title: 'Zanshin',
      builder: (_) => _content(mainSheet, field: field, text: text),
    );
    Widget root = WindowManager(initialWindows: <WindowEntry>[main]);
    if (menuBar) {
      final PlatformMenuDelegate original = WidgetsBinding.instance.platformMenuDelegate;
      WidgetsBinding.instance.platformMenuDelegate = delegate = _MenuDelegate();
      addTearDown(() => WidgetsBinding.instance.platformMenuDelegate = original);
      root = AppMenuBar(model: menu, child: root);
    }
    await tester.pumpWidget(root, wrapWithView: false);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: projectsWindowTitle,
      builder: (_) => _content(projectsSheet),
      dialog: projectsWindowSpec,
    );
    await tester.pump();
    windows.setCloseHandler(mainWindowKey, () async => closes.add(mainWindowKey));
  }

  /// Makes the window [key] the key window.
  void focus(String key) => tracker.didChangeViewFocus(
    ViewFocusEvent(
      viewId: windows.viewIdOf(key)!,
      state: ViewFocusState.focused,
      direction: ViewFocusDirection.undefined,
    ),
  );

  /// Binds a graph of `_wc` (@) over `_mid` over `_base`.
  Future<void> bindGraph(WidgetTester tester) async {
    final ScriptedGraphSource source = this.source = ScriptedGraphSource(
      respond: (_) => keysLayout(<String>[_wc, _mid, _base], at: _wc),
    );
    final GraphViewModel model = this.model = GraphViewModel();
    final GraphPreferences preferences = (this.preferences = GraphPreferences(store))
      ..init(model, source, actions: graphActions = _GraphActions());
    menu.graph.value = GraphMenuBinding(
      model: model,
      preferences: preferences,
      focusSearch: () => searches++,
    );
    await tester.pump();
  }

  /// Disposes the graph (its minute tick is a timer).
  void unbindGraph() {
    menu.graph.value = null;
    model?.dispose();
    preferences?.dispose();
  }

  List<PlatformMenuItem> get menus => menu.menus(platformStrings());

  /// The item [label] below the top menus (so "Edit" is Change › Edit, not the Edit menu).
  PlatformMenuItem item(String label) => _all(
    menus.expand((menu) => (menu as PlatformMenu).menus).toList(),
  ).firstWhere((item) => item.label == label && item is! PlatformMenuItemGroup);

  bool enabled(String label) => item(label).onSelected != null;

  void select(String label) => item(label).onSelected!();
}

void main() {
  late bool windowingWasEnabled;
  setUp(() {
    windowingWasEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
  });
  tearDown(() => isWindowingEnabled = windowingWasEnabled);

  testWidgets('the eight top menus in order with the DS items, and no key equivalent repeats', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    final List<PlatformMenuItem> menus = rig.menus;

    expect(menus.map((m) => m.label), <String>['Zanshin', 'File', 'Edit', 'View', 'Change', 'Go', 'Window', 'Help']);
    expect(_labels(menus, 'Zanshin'), <String>['Settings…']);
    expect(_labels(menus, 'File'), <String>['All Projects…', 'Open Recent', 'Project Settings…', 'Close Window']);
    expect(_labels(menus, 'Edit'), <String>['Undo', 'Redo', 'Cut', 'Copy', 'Paste', 'Select All', 'Find']);
    expect(_labels(menus, 'View'), <String>[
      'Free',
      'Compact',
      'Detailed Cards',
      'Group Stacks',
      'Edit Configurations…',
      'Show Minimap',
      'Reload',
    ]);
    expect(_labels(menus, 'Change'), <String>[
      'New Change',
      'Describe…',
      'Edit',
      'Squash into Parent',
      'Revert',
      'Abandon',
      'Fetch',
      'Push…',
    ]);
    expect(_labels(menus, 'Go'), <String>['Selection', 'Working Copy (@)', 'Parent', 'Child']);
    expect(_labels(menus, 'Window'), <String>['Projects']);
    expect(_labels(menus, 'Help'), <String>['Zanshin Help', 'jj Documentation ↗']);
    expect(
      _all(menus).whereType<PlatformProvidedMenuItem>().map((item) => item.type),
      <PlatformProvidedMenuItemType>[
        .about,
        .servicesSubmenu,
        .hide,
        .hideOtherApplications,
        .showAllApplications,
        .quit,
        .toggleFullScreen,
        .minimizeWindow,
        .zoomWindow,
        .arrangeWindowsInFront,
      ],
    );

    String describe(SingleActivator a) => '${a.control}${a.alt}${a.shift}${a.meta}${a.trigger.keyId}';
    final shortcuts = <String>[
      for (final item in _all(menus))
        if (item.shortcut case final SingleActivator shortcut) describe(shortcut),
    ];
    // The system items' own: ⌘H, ⌥⌘H, ⌘Q, ⌘M, ⌃⌘F.
    final provided = <String>[
      describe(const SingleActivator(LogicalKeyboardKey.keyH, meta: true)),
      describe(const SingleActivator(LogicalKeyboardKey.keyH, meta: true, alt: true)),
      describe(const SingleActivator(LogicalKeyboardKey.keyQ, meta: true)),
      describe(const SingleActivator(LogicalKeyboardKey.keyM, meta: true)),
      describe(const SingleActivator(LogicalKeyboardKey.keyF, meta: true, control: true)),
    ];
    expect(shortcuts, hasLength(19));
    expect(<String>{...shortcuts, ...provided}, hasLength(shortcuts.length + provided.length));
  });

  testWidgets('items without a handler story are grey; graph items are grey while no graph is bound', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    for (final label in <String>[
      'Settings…',
      'Project Settings…',
      'Edit Configurations…',
      'Show Minimap',
      'Describe…',
      'Fetch',
      'Push…',
      'Zanshin Help',
      // No graph bound:
      'Undo', 'Redo', 'Find', 'Free', 'Compact', 'Detailed Cards', 'Group Stacks', 'Reload',
      'New Change', 'Edit', 'Squash into Parent', 'Revert', 'Abandon',
      'Selection', 'Working Copy (@)', 'Parent', 'Child',
      // No key window yet; no recent project.
      'Close Window', 'Open Recent',
    ]) {
      expect(rig.enabled(label), isFalse, reason: label);
    }
    expect(rig.item('Open Recent'), isNot(isA<PlatformMenu>()));

    rig
      ..select('All Projects…')
      ..select('Projects');
    expect(rig.actions.projects, 2);
    rig.select('jj Documentation ↗');
    await tester.pump();
    expect(rig.urls, <Uri>[Uri.parse('https://docs.jj-vcs.dev/v0.46.0/')]);
  });

  testWidgets("Close Window runs the key window's red-button path: the project window's handler, Projects closes", (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    rig
      ..focus(mainWindowKey)
      ..select('Close Window');
    await tester.pump();
    expect(rig.closes, <String>[mainWindowKey]);
    expect(rig.windows.isOpen(mainWindowKey), isTrue);

    rig
      ..focus(projectsWindowKey)
      ..select('Close Window');
    await tester.pump();
    expect(rig.windows.isOpen(projectsWindowKey), isFalse);
  });

  testWidgets('no selection: the Change items read @ and act on its full id; Edit and Revert are grey', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);

    expect(rig.enabled('Edit'), isFalse);
    expect(rig.enabled('Revert'), isFalse);
    expect(rig.enabled('Squash @ into Parent'), isTrue);
    expect(rig.enabled('Selection'), isFalse);
    expect(rig.enabled('Parent'), isFalse);
    rig.select('Abandon @');
    await tester.pump();
    expect(rig.graphActions!.ran.single.command, 'jj abandon $_wc');
    rig.unbindGraph();
  });

  testWidgets('a selection: the Change items name its id, Go › Selection, Parent and Child are enabled', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    rig.model!.select(_mid);

    expect(rig.enabled('Selection'), isTrue);
    rig.select('Edit kmnvxoqp');
    await tester.pump();
    rig.select('Revert kmnvxoqp');
    await tester.pump();
    rig.select('Squash kmnvxoqp into Parent');
    await tester.pump();
    rig.select('New Change');
    await tester.pump();
    expect(rig.graphActions!.ran.map((a) => a.command), <String>[
      'jj edit $_mid',
      'jj revert -r $_mid -B @',
      'jj squash -r $_mid',
      'jj new $_mid',
    ]);

    rig.select('Parent');
    expect(rig.model!.selected, _base);
    rig.select('Child');
    expect(rig.model!.selected, _mid);
    rig.unbindGraph();
  });

  testWidgets('Go › Selection and Working Copy request the scroll and leave the selection', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    rig.model!.select(_mid);

    rig.select('Selection');
    expect((rig.model!.reveal?.key, rig.model!.selected), (_mid, _mid));
    rig.select('Working Copy (@)');
    expect((rig.model!.reveal?.key, rig.model!.selected), (_wc, _mid));
    rig.unbindGraph();
  });

  testWidgets('Undo names the own operation and runs undoLast; after a foreign operation it is grey', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    expect(rig.enabled('Undo'), isFalse, reason: 'no own operation yet');
    rig.model!.select(_mid);
    rig.select('Abandon kmnvxoqp');
    await tester.pump();

    expect(rig.enabled('Undo Abandon kmnvxoqp'), isTrue);
    rig.select('Undo Abandon kmnvxoqp');
    await tester.pump();
    expect(rig.graphActions!.ran.last, isA<GraphUndo>());
    expect(rig.enabled('Redo Abandon kmnvxoqp'), isTrue);

    rig.graphActions!.head = 'foreign';
    rig.source!.emit(const OpHeadsChangedEvent(0, <String>[]));
    await tester.pump();
    expect(rig.enabled('Redo'), isFalse);
    expect(rig.enabled('Undo'), isFalse);
    rig.unbindGraph();
  });

  testWidgets('while an action runs the Change and Undo items are grey', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    rig.select('Abandon @');
    await tester.pump();
    expect(rig.enabled('Undo Abandon @'), isTrue);

    final Completer<void> gate = rig.graphActions!.gate = Completer<void>();
    rig.select('New Change');
    await tester.pump();
    // A busy graph is not offered at all, so the items lose their target too.
    for (final label in <String>['New Change', 'Abandon', 'Squash into Parent', 'Undo', 'Working Copy (@)']) {
      expect(rig.enabled(label), isFalse, reason: label);
    }
    gate.complete();
    await tester.pump();
    expect(rig.enabled('New Change'), isTrue);
    rig.unbindGraph();
  });

  testWidgets('a sheet in the project window greys the project items; Settings-side items are unaffected', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(
      tester,
      projects: <ProjectEntry>[ProjectEntry(path: '/p/other', name: 'other', lastOpened: DateTime.utc(2026, 10))],
    );
    await rig.bindGraph(tester);
    rig.focus(mainWindowKey);
    expect(rig.item('Open Recent'), isA<PlatformMenu>());
    expect(rig.enabled('Find'), isTrue);

    rig.mainSheet.value = true;
    await tester.pump();
    for (final label in <String>[
      'Close Window',
      'Open Recent',
      'Reload',
      'Find',
      'Undo',
      'Redo',
      'Free',
      'Group Stacks',
      'New Change',
      'Squash into Parent',
      'Abandon',
      'Working Copy (@)',
    ]) {
      expect(rig.enabled(label), isFalse, reason: label);
    }
    expect(rig.item('Open Recent'), isNot(isA<PlatformMenu>()));
    expect(rig.enabled('All Projects…'), isTrue);
    expect(rig.enabled('Projects'), isTrue);

    rig.focus(projectsWindowKey);
    expect(rig.enabled('Close Window'), isTrue, reason: 'the sheet is not in the key window');
    rig.projectsSheet.value = true;
    await tester.pump();
    expect(rig.enabled('Close Window'), isFalse);
    rig.unbindGraph();
  });

  testWidgets('View › Reload refreshes the session once and reloads the bound graph; Find focuses the graph search', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(
      tester,
      projects: <ProjectEntry>[ProjectEntry(path: '/p/other', name: 'other', lastOpened: DateTime.utc(2026, 10))],
    );
    await rig.bindGraph(tester);
    final int requests = rig.source!.requests.length;

    rig.select('Reload');
    await tester.pump();
    expect(rig.session.refreshes, 1);
    expect(rig.source!.requests, hasLength(requests + 1));

    rig.select('Find');
    expect(rig.searches, 1);

    (rig.item('Open Recent') as PlatformMenu).menus.single.onSelected!();
    await tester.pump();
    expect(rig.session.opens, <String>['/p/other']);

    rig
      ..select('Free')
      ..select('Detailed Cards');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(rig.store.value.graph.detailedCards, isNot(const GraphSettings().detailedCards));
    rig.unbindGraph();
  });

  testWidgets('a focused text field comes first: plain Undo acts on the text, the text items enable', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    rig.select('Abandon @');
    await tester.pump();
    expect(rig.enabled('Undo Abandon @'), isTrue);
    for (final label in <String>['Cut', 'Copy', 'Paste', 'Select All']) {
      expect(rig.enabled(label), isFalse, reason: '$label without a text field');
    }

    rig.field.requestFocus();
    await tester.pump();
    expect(rig.item('Undo').onSelected, isNotNull, reason: 'plain "Undo" for the text field');
    expect(rig.enabled('Select All'), isTrue);
    expect(rig.enabled('Copy'), isTrue);
    final int ran = rig.graphActions!.ran.length;
    rig.select('Undo');
    await tester.pump();
    expect(rig.graphActions!.ran, hasLength(ran), reason: 'no GraphUndo');

    rig.field.unfocus();
    await tester.pump();
    expect(rig.enabled('Select All'), isFalse);
    expect(rig.enabled('Copy'), isFalse);
    rig.unbindGraph();
  });

  testWidgets("AppMenuBar hands the platform the model's menus and rebuilds when the key window changes", (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester, menuBar: true);
    await tester.pump();
    List<PlatformMenuItem> last() => rig.delegate!.sets.last;
    PlatformMenuItem close() =>
        _all(last()).firstWhere((item) => item.label == 'Close Window' && item is! PlatformMenuItemGroup);

    expect(last().map((m) => m.label), <String>['Zanshin', 'File', 'Edit', 'View', 'Change', 'Go', 'Window', 'Help']);
    expect(close().onSelected, isNull);

    final int sets = rig.delegate!.sets.length;
    rig.focus(mainWindowKey);
    // The model tells its listeners after a microtask, so the rebuild lands on the next frame.
    await tester.pump();
    await tester.pump();
    expect(rig.delegate!.sets.length, greaterThan(sets));
    expect(close().onSelected, isNotNull);
  });
}
