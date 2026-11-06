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
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_remote_sync.dart';
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

  /// The open repository the menu sees, when set.
  ProjectRepo? openRepo;

  @override
  ProjectRepo? get repo => openRepo ?? super.repo;

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
  var configurations = 0;

  @override
  Future<void> openProjects() async => projects++;

  @override
  Future<void> openRevsetConfigs() async => configurations++;

  final settings = <SettingsTarget?>[];

  @override
  Future<void> openSettings({SettingsTarget? target}) async => settings.add(target);
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
  _MenuDelegate(this.events);

  final sets = <List<PlatformMenuItem>>[];

  /// The rig's shared log of what reaches the platform, in order.
  final List<String> events;

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) {
    sets.add(topLevelMenus);
    events.add('setMenus');
  }

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

  /// `setMenus` and `apply` in the order they reach the platform.
  final events = <String>[];

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
      ..attach(windows, actions, store)
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
      WidgetsBinding.instance.platformMenuDelegate = delegate = _MenuDelegate(events);
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
  Future<void> bindGraph(
    WidgetTester tester, {
    ValueChanged<String>? squash,
    SyncModel Function(GraphViewModel)? sync,
  }) async {
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
      squash: squash,
      sync: sync?.call(model),
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
      'Zoom In',
      'Zoom Out',
      'Actual Size',
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
    // ⌘− and ⌘0 (Story 11.20); Zoom In's ⌘+ is a character activator, below.
    expect(shortcuts, hasLength(21));
    expect(<String>{...shortcuts, ...provided}, hasLength(shortcuts.length + provided.length));
  });

  testWidgets('View › Zoom In ⌘+, Zoom Out ⌘−, Actual Size ⌘0 step appearance.zoom, each grey at its end', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    expect(rig.item('Zoom In').shortcut, const CharacterActivator('+', meta: true));
    expect(rig.item('Zoom Out').shortcut, const SingleActivator(LogicalKeyboardKey.minus, meta: true));
    expect(rig.item('Actual Size').shortcut, const SingleActivator(LogicalKeyboardKey.digit0, meta: true));
    Future<void> select(String label) async {
      rig.select(label);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    // At 100: Actual Size is grey.
    expect(rig.enabled('Actual Size'), isFalse);
    expect(rig.enabled('Zoom In'), isTrue);
    expect(rig.enabled('Zoom Out'), isTrue);
    await select('Zoom In');
    expect(rig.store.value.appearance.zoom, 110);
    expect(rig.enabled('Actual Size'), isTrue);
    await select('Zoom In');
    await select('Zoom In');
    expect(rig.store.value.appearance.zoom, 150);
    expect(rig.enabled('Zoom In'), isFalse, reason: 'grey at 150');
    expect(rig.enabled('Zoom Out'), isTrue);
    expect(rig.enabled('Actual Size'), isTrue);
    await select('Actual Size');
    expect(rig.store.value.appearance.zoom, 100);
    await select('Zoom Out');
    expect(rig.store.value.appearance.zoom, 90);
    expect(rig.enabled('Zoom Out'), isFalse, reason: 'grey at 90');
  });

  testWidgets(
    'Settings… ⌘, opens Settings on the tab shown last; Project Settings… on Project once a project is open',
    (
      tester,
    ) async {
      final rig = _Rig();
      await rig.setUp(tester);
      final PlatformMenuItem settings = rig.item('Settings…');
      expect(settings.shortcut, const SingleActivator(LogicalKeyboardKey.comma, meta: true));

      rig.select('Settings…');
      await tester.pump();
      expect(rig.actions.settings, <SettingsTarget?>[null]);
      expect(rig.enabled('Project Settings…'), isFalse);

      rig.session.openRepo = await tester.runAsync(() => FakeProjectRepos().open('/r/zanshin'));
      expect(rig.enabled('Project Settings…'), isTrue);
      rig.select('Project Settings…');
      await tester.pump();
      expect(rig.actions.settings, <SettingsTarget?>[null, SettingsTarget.project]);
    },
  );

  testWidgets("Change › Fetch runs the bound sync's fetch and Push… (⇧⌘P) opens its sheet; nothing pushes", (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    final remotes = FakeRemoteSync();
    final toasts = ShellToasts();
    late final SyncModel sync;
    await rig.bindGraph(
      tester,
      sync: (model) => sync = SyncModel(
        sync: remotes,
        graph: model,
        toasts: toasts,
        pollSetting: () => RemotePollSetting.off,
      ),
    );
    await tester.runAsync(sync.reloadRemotes);
    await tester.pump();
    expect(rig.enabled('Fetch'), isTrue);
    expect(rig.item('Fetch').shortcut, isNull);
    expect(rig.enabled('Push…'), isTrue);

    rig.select('Push…');
    await tester.pump();
    expect(sync.pushSheet, isNotNull);
    expect(rig.enabled('Fetch'), isFalse, reason: 'not while the sheet is open');
    sync.pushSheetClosed();
    rig.select('Fetch');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(remotes.log, contains('fetch'));
    expect(remotes.pushes, isEmpty);

    rig.unbindGraph();
    sync.dispose();
    toasts.dispose();
  });

  testWidgets('items without a handler story are grey; graph items are grey while no graph is bound', (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    for (final label in <String>[
      // No project open:
      'Project Settings…',
      'Describe…',
      'Fetch',
      'Push…',
      'Zanshin Help',
      // No graph bound:
      'Undo', 'Redo', 'Find', 'Free', 'Compact', 'Detailed Cards', 'Group Stacks', 'Show Minimap', 'Reload',
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
    // Story 10.22: View › Edit Configurations… (⌥⌘L) opens the jj log Configurations window, with or without a graph.
    final PlatformMenuItem configurations = rig.item('Edit Configurations…');
    expect(configurations.shortcut, const SingleActivator(LogicalKeyboardKey.keyL, meta: true, alt: true));
    rig.select('Edit Configurations…');
    await tester.pump();
    expect(rig.actions.configurations, 1);
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
    // The close handler runs from a timer (AppWindows._closeRequested).
    await tester.pump(Duration.zero);
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

  testWidgets('Squash into Parent goes through the bound squash callback (the inspector) when there is one', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    final squashed = <String>[];
    await rig.bindGraph(tester, squash: squashed.add);
    rig.model!.select(_mid);
    rig.select('Squash kmnvxoqp into Parent');
    await tester.pump();
    expect(squashed, <String>[_mid]);
    expect(rig.graphActions!.ran, isEmpty);
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

  test('Undo and Redo name Track / Untrack by the remote bookmark (Story 10.14)', () {
    final model = GraphViewModel();
    addTearDown(model.dispose);
    final AppLocalizations s = platformStrings();
    expect(AppMenuModel.actionName(s, model, const GraphBookmarkTrack('main', 'origin')), 'Track main@origin');
    expect(
      AppMenuModel.actionName(s, model, const GraphUndo(GraphBookmarkUntrack('main', 'origin'))),
      'Untrack main@origin',
    );
  });

  test('Undo and Redo name the drop verbs (Story 10.10)', () {
    final model = GraphViewModel();
    addTearDown(model.dispose);
    final AppLocalizations s = platformStrings();
    String name(GraphAction action) => AppMenuModel.actionName(s, model, action);
    const s1 = <String>['kmnvxoqpzzzz'];
    const t1 = <String>['vruxwmqvzzzz'];
    expect(name(const GraphRebase(source: s1, onto: t1)), 'Move kmnvxoqp onto vruxwmqv');
    expect(name(const GraphRebase(revisions: s1, insertAfter: t1)), 'Insert kmnvxoqp after vruxwmqv');
    expect(name(const GraphUndo(GraphRebase(revisions: s1, insertBefore: t1))), 'Insert kmnvxoqp before vruxwmqv');
    expect(name(const GraphDuplicate(revisions: s1, onto: t1)), 'Duplicate kmnvxoqp onto vruxwmqv');
    expect(
      name(const GraphNew(parents: <String>['vruxwmqvzzzz', 'kmnvxoqpzzzz'])),
      'New Merge Change of kmnvxoqp and vruxwmqv',
    );
  });

  test('Undo and Redo name Commit / Split by the change (Story 10.25)', () {
    final model = GraphViewModel();
    addTearDown(model.dispose);
    final AppLocalizations s = platformStrings();
    expect(
      AppMenuModel.actionName(s, model, const GraphCommit('kmnvxoqpzzzz', message: <String>['Fix'])),
      'Commit kmnvxoqp',
    );
    expect(
      AppMenuModel.actionName(s, model, const GraphSplit('kmnvxoqpzzzz', message: <String>[''], paths: <String>['a'])),
      'Split kmnvxoqp',
    );
    expect(
      AppMenuModel.actionName(s, model, const GraphRedo(GraphCommit('kmnvxoqpzzzz', message: <String>['']))),
      'Commit kmnvxoqp',
    );
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

  testWidgets("the Undo Timeline's verbs name themselves: Redo ‹command› after an undo, Undo Restore to ‹id›", (
    tester,
  ) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    unawaited(
      rig.model!.undoOperation('op0', const GraphLoggedOperation('op0', 'new empty commit', args: 'jj new main')),
    );
    await tester.pump();
    expect(rig.enabled('Redo jj new main'), isTrue);
    unawaited(rig.model!.restoreOperation('1a2b3c4d5e6f'));
    await tester.pump();
    expect(rig.enabled('Undo Restore to 1a2b3c4d5e6f'), isTrue);
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

  test('windowItemsEnabled follows the key window (Story 11.17)', () {
    Map<String, bool> e({required bool minimize, required bool zoom, required bool fullScreen}) => <String, bool>{
      'performMiniaturize:': minimize,
      'performZoom:': zoom,
      'toggleFullScreen:': fullScreen,
    };
    expect(AppMenuModel.windowItemsEnabled(null), e(minimize: false, zoom: false, fullScreen: false));
    expect(AppMenuModel.windowItemsEnabled(mainWindowKey), e(minimize: true, zoom: true, fullScreen: true));
    expect(AppMenuModel.windowItemsEnabled(projectsWindowKey), e(minimize: false, zoom: true, fullScreen: false));
    expect(AppMenuModel.windowItemsEnabled(settingsWindowKey), e(minimize: false, zoom: false, fullScreen: false));
    expect(
      AppMenuModel.windowItemsEnabled(revsetConfigsWindowKey),
      e(minimize: false, zoom: true, fullScreen: false),
    );
  });

  testWidgets("nativeState checks the View toggles after the bound graph's preferences", (tester) async {
    final rig = _Rig();
    await rig.setUp(tester);
    await rig.bindGraph(tester);
    rig.preferences!
      ..setDetailedCards(true)
      ..setGroupStacks(false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    Map<String, bool> checked() => <String, bool>{
      for (final entry in rig.menu.nativeState(platformStrings())['checked']! as List<Map<String, Object>>)
        if (entry['menu'] == 'View') entry['item']! as String: entry['checked']! as bool,
    };
    expect(checked(), <String, bool>{'Detailed Cards': true, 'Group Stacks': false, 'Show Minimap': true});

    // Story 10.16: View › Show Minimap flips the stored preference, and its check follows.
    rig.select('Show Minimap');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(rig.store.value.graph.showMinimap, isFalse);
    expect(checked(), <String, bool>{'Detailed Cards': true, 'Group Stacks': false, 'Show Minimap': false});

    rig.unbindGraph();
    expect(checked(), <String, bool>{'Detailed Cards': false, 'Group Stacks': false, 'Show Minimap': false});
  });

  testWidgets('AppMenuBar applies the native state after each build, following the key window', (tester) async {
    final rig = _Rig();
    final applied = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menuStateChannel, (call) async {
      if (call.method == 'apply') {
        applied.add(call.arguments as Map<Object?, Object?>);
        rig.events.add('apply');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menuStateChannel, null));
    await rig.setUp(tester, menuBar: true);
    await tester.pump();
    Map<Object?, Object?> enabled() => applied.last['enabled']! as Map<Object?, Object?>;
    bool? detailedCards() =>
        <Object?, Object?>{
              for (final entry in (applied.last['checked']! as List<Object?>).cast<Map<Object?, Object?>>())
                entry['item']: entry['checked'],
            }['Detailed Cards']
            as bool?;
    expect(enabled().values, everyElement(isFalse), reason: 'no key window yet');

    rig.focus(mainWindowKey);
    await tester.pump();
    await tester.pump();
    expect(enabled(), <String, bool>{'performMiniaturize:': true, 'performZoom:': true, 'toggleFullScreen:': true});

    rig.focus(projectsWindowKey);
    await tester.pump();
    await tester.pump();
    expect(enabled(), <String, bool>{'performMiniaturize:': false, 'performZoom:': true, 'toggleFullScreen:': false});
    expect(rig.events.lastIndexOf('apply'), greaterThan(rig.events.lastIndexOf('setMenus')), reason: 'after setMenus');

    await rig.bindGraph(tester);
    for (final on in <bool>[true, false]) {
      rig.preferences!.setDetailedCards(on);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
      expect(detailedCards(), on);
    }
    rig.unbindGraph();
  });
}
