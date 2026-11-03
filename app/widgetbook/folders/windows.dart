// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart' show RevsetMember;
import 'package:zanshin/src/features/settings/settings_view_model.dart' show SettingsRepoReads;
import 'package:zanshin/src/features/settings/settings_window.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/shell/app_menu.dart' show GraphMenuBinding;
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/window_chrome_builder.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart'
    show RevsetCount, RevsetCounts, TopologyRef, TopologyRefKind, ZanshinWarning;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../catalogue.dart' show catalogueAppBuilder;
import '../demo_projects_fakes.dart';
import '../graph/fake_graph_search_source.dart';
import '../graph/fake_graph_source.dart';
import '../graph/graph_recordings.g.dart';
import 'graph.dart' show catalogueOperationId, recordedLayout, requestedLayout;
import 'shell.dart' show FloatingShellDemo, ShellDemoState;

/// Hands the catalogue's [AppWindows] and its [ActiveWindowTracker] to the use cases that open real windows.
class CatalogueWindows extends InheritedWidget {
  /// Provides [windows] and [tracker] to [child].
  const CatalogueWindows({required this.windows, required this.tracker, required super.child, super.key});

  /// The catalogue process's windows.
  final AppWindows windows;

  /// Which catalogue window is key, for the opened windows' inactive look (Story 11.12).
  final ActiveWindowTracker tracker;

  /// The nearest windows (read from callbacks; they never change, so nothing depends on them).
  static AppWindows of(BuildContext context) => _scope(context).windows;

  /// The nearest tracker, read like [of].
  static ActiveWindowTracker trackerOf(BuildContext context) => _scope(context).tracker;

  static CatalogueWindows _scope(BuildContext context) {
    final CatalogueWindows? scope = context.getInheritedWidgetOfExactType<CatalogueWindows>();
    assert(scope != null, 'No CatalogueWindows above the catalogue.');
    return scope!;
  }

  @override
  bool updateShouldNotify(CatalogueWindows oldWidget) =>
      !identical(windows, oldWidget.windows) || !identical(tracker, oldWidget.tracker);
}

/// The root of every window the catalogue opens: [catalogueAppBuilder] over [child] with the window's chrome report
/// (Story 11.4) and its key status from [tracker] (Story 11.12), so its root takes the measured traffic-light block,
/// full screen and the inactive look as the app's window root does; the subtree is keyed `window:<windowKey>` for
/// Marionette's `ancestor_keys`. [sizeToContent] for a window without a size.
///
/// One [WindowChromeBuilder] per window; the new window is no descendant of the catalogue's, so it takes the
/// [shellTheme] and the [tracker] it was opened with.
class CatalogueWindowRoot extends StatelessWidget {
  /// The root of the catalogue window [windowKey] showing [child].
  const CatalogueWindowRoot({
    required this.windowKey,
    required this.tracker,
    required this.shellTheme,
    required this.child,
    this.theme,
    this.sizeToContent = false,
    super.key,
  });

  /// The window's key.
  final String windowKey;

  /// The theme of the use case that opened the window (the Appearance addon's), or null to follow macOS.
  final ZsTheme? theme;

  /// Which window is key.
  final ActiveWindowTracker tracker;

  /// The shell theme as the catalogue had it when the window opened.
  final ShellTheme? shellTheme;

  /// Whether the window is sized to its content.
  final bool sizeToContent;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) => ZsAppearanceOverride(
    theme: theme,
    child: ZsShellScope(
      shellTheme: shellTheme,
      child: WindowChromeBuilder(
        builder: (context, chrome) => ListenableBuilder(
          listenable: tracker,
          builder: (context, _) => catalogueAppBuilder(
            context,
            KeyedSubtree(key: ValueKey<String>('window:$windowKey'), child: child),
            chrome: chrome,
            inactive: !tracker.isActive(View.of(context).viewId),
            sizeToContent: sizeToContent,
          ),
        ),
      ),
    ),
  );
}

/// The "Windows" folder: use cases that open a real window of their own, as the app's dialog windows do.
///
/// Stories 11.12 (window chrome kinds, dialog windows, the Window scaffold), 11.6 (Projects), 11.7 (Settings) and
/// 10.22 (Configurations) add their windows here. Each window's builder returns a [CatalogueWindowRoot] over its
/// content.
final windowsFolder = WidgetbookFolder(
  name: 'Windows',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Window fill',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Window fill',
          builder: (context) => const Center(child: _OpenWindowFill()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Window scaffold',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Resizable',
          builder: (context) => const _ScaffoldUseCase(kind: _ScaffoldKind.resizable),
        ),
        WidgetbookUseCase(
          name: 'Content-sized',
          builder: (context) => const _ScaffoldUseCase(kind: _ScaffoldKind.contentSized),
        ),
        WidgetbookUseCase(
          name: 'Floating',
          builder: (context) => const _ScaffoldUseCase(kind: _ScaffoldKind.floating),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Floating shell',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Floating shell',
          builder: (context) => const Center(child: _OpenFloatingShell()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Projects window',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Projects window',
          builder: (context) => const Center(child: _OpenProjectsWindow()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Settings window',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Settings window',
          builder: (context) => const Center(child: _OpenSettingsWindow()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Configurations window',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Configurations window',
          builder: (context) => const Center(child: _OpenRevsetConfigsWindow()),
        ),
      ],
    ),
  ],
);

/// Opens [content] in the catalogue window [key] titled [title]: a dialog window of [dialog]'s spec, or a project
/// window of [size] without one; the new window is no descendant of the catalogue's, so it takes the shell theme and
/// the tracker as they are when [context]'s button is pressed.
void _open(
  BuildContext context, {
  required String key,
  required String title,
  required Widget content,
  DialogWindowSpec? dialog,
  Size? size,
}) {
  final ZsShellScope? shell = context.getInheritedWidgetOfExactType<ZsShellScope>();
  final ActiveWindowTracker tracker = CatalogueWindows.trackerOf(context);
  final root = CatalogueWindowRoot(
    windowKey: key,
    tracker: tracker,
    shellTheme: shell?.shellTheme,
    // The use case's theme (the Appearance addon's), not macOS's: a paper use case opens a paper window.
    theme: ZsAppearance.maybeOf(context)?.theme,
    sizeToContent: dialog != null && dialog.size == null,
    child: content,
  );
  unawaited(
    CatalogueWindows.of(context).openOrActivate(
      key: key,
      title: title,
      size: size,
      dialog: dialog,
      builder: (context) => root,
    ),
  );
}

class _OpenWindowFill extends StatelessWidget {
  const _OpenWindowFill();

  /// A resizable dialog window: its first size and its smallest.
  static const _spec = DialogWindowSpec(
    size: Size(560, 360),
    constraints: BoxConstraints(minWidth: 320, minHeight: 200),
  );

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open a window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-window-fill',
    onPressed: () => _open(
      context,
      key: 'widgetbook-window-fill',
      title: 'Window fill',
      dialog: _spec,
      content: const ZsWindowFill(child: Center(child: Text('A window on ZsWindowFill'))),
    ),
  );
}

/// The Window scaffold's three native modes (Story 11.12 items 2, 3, 6, 8).
enum _ScaffoldKind {
  /// Titled | Closable | Resizable, the full frame remembered.
  resizable(
    title: 'Resizable',
    key: 'widgetbook-window-scaffold-resizable',
    spec: DialogWindowSpec(
      size: Size(720, 480),
      constraints: BoxConstraints(minWidth: 560, minHeight: 320),
    ),
  ),

  /// Titled | Closable, 620 wide, the height following the content up to 740, only the position remembered with
  /// its top edge held (Settings' shape, DS readme.md:189). No minimum (see `DialogWindowSpec.size`): the scaffold's
  /// stretched column takes the 620.
  contentSized(
    title: 'Content-sized',
    key: 'widgetbook-window-scaffold-content-sized',
    spec: DialogWindowSpec(
      constraints: BoxConstraints(maxWidth: 620, maxHeight: 740),
      resizable: false,
      frame: WindowFrameMode.position,
    ),
  ),

  /// Resizable and floating while Zanshin is active (Configurations' level, decision 16.19).
  floating(
    title: 'Floating',
    key: 'widgetbook-window-scaffold-floating',
    spec: DialogWindowSpec(
      size: Size(520, 340),
      constraints: BoxConstraints(minWidth: 400, minHeight: 260),
      level: WindowLevel.floatingWhileActive,
    ),
  );

  const _ScaffoldKind({required this.title, required this.key, required this.spec});

  /// The use case's and the window's title.
  final String title;

  /// The window's key, its frame key.
  final String key;

  /// The window.
  final DialogWindowSpec spec;
}

/// A Window scaffold use case: the button that opens the real window and, below it, the same scaffold in a panel of
/// the window's size, which follows the Appearance addon (theme, inactive) for the comparison with the DS window card.
class _ScaffoldUseCase extends StatelessWidget {
  const _ScaffoldUseCase({required this.kind});

  final _ScaffoldKind kind;

  @override
  Widget build(BuildContext context) {
    final Size? size = kind.spec.size;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: <Widget>[
          ZsButton(
            label: 'Open the ${kind.title.toLowerCase()} window',
            variant: ZsButtonVariant.primary,
            identifier: 'open-${kind.key.substring('widgetbook-'.length)}',
            onPressed: () => _open(
              context,
              key: kind.key,
              title: kind.title,
              dialog: kind.spec,
              content: _ScaffoldDemo(kind: kind),
            ),
          ),
          SizedBox(
            width: size?.width ?? kind.spec.constraints.maxWidth,
            height: size?.height,
            child: _ScaffoldDemo(kind: kind),
          ),
        ],
      ),
    );
  }
}

/// The window content of a Window scaffold use case.
class _ScaffoldDemo extends StatefulWidget {
  const _ScaffoldDemo({required this.kind});

  final _ScaffoldKind kind;

  @override
  State<_ScaffoldDemo> createState() => _ScaffoldDemoState();
}

class _ScaffoldDemoState extends State<_ScaffoldDemo> {
  final _search = ZsTextEditingController();
  final _note = ZsTextEditingController();
  var _tab = 'general';
  var _moreRows = false;

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (widget.kind) {
    _ScaffoldKind.resizable => ZsWindowScaffold(
      title: widget.kind.title,
      header: <Widget>[
        SizedBox(
          width: 200,
          child: ZsSearchField(controller: _search, placeholder: 'Search…', identifier: 'scaffold-search'),
        ),
        ZsButton(
          label: 'Add',
          variant: ZsButtonVariant.primary,
          size: ZsButtonSize.md,
          icon: ZI.plus,
          identifier: 'scaffold-primary',
          onPressed: () {},
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: <Widget>[
            const Text('A text field in a window that is not the catalogue takes typed input.'),
            SizedBox(
              width: 320,
              child: ZsTextField(
                controller: _note,
                placeholder: 'Type here',
                label: 'Note',
                identifier: 'scaffold-text-field',
              ),
            ),
          ],
        ),
      ),
    ),
    _ScaffoldKind.contentSized => ZsWindowScaffold(
      title: 'General',
      titleHidden: true,
      align: ZsWindowHeaderAlign.center,
      header: <Widget>[
        ZsSegmented<String>(
          variant: ZsSegmentedVariant.tabs,
          label: 'Scope',
          identifier: 'scaffold-tabs',
          segments: const <ZsSegment<String>>[
            ZsSegment<String>(value: 'general', label: 'General'),
            ZsSegment<String>(value: 'project', label: 'Project'),
          ],
          value: _tab,
          onChanged: (tab) => setState(() => _tab = tab),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            Row(
              spacing: 12,
              children: <Widget>[
                const Expanded(child: Text('More rows — the height follows, the top edge stays')),
                ZsSwitch(
                  value: _moreRows,
                  label: 'More rows',
                  identifier: 'scaffold-more-rows',
                  onChanged: (more) => setState(() => _moreRows = more),
                ),
              ],
            ),
            for (var i = 1; i <= (_moreRows ? 8 : 2); i++) Text('Row $i'),
          ],
        ),
      ),
    ),
    _ScaffoldKind.floating => ZsWindowScaffold(
      title: widget.kind.title,
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Floats above the other windows while Zanshin is active, and drops back when it resigns.'),
        ),
      ),
    ),
  };
}

/// Opens Story 11.3's floating shell with a demo island in every slot in a real 1440 × 900 window, resizable down to
/// the project window's 880 × 560 minimum (decision 16.37, `defaultWindowConstraints`), so a reviewer drags it through
/// the collapse widths. Its [CatalogueWindowRoot] lays the shell out on the window's chrome report: the measured
/// traffic-light block, and full screen.
class _OpenFloatingShell extends StatelessWidget {
  const _OpenFloatingShell();

  static const _size = Size(1440, 900);

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open the floating shell',
    variant: ZsButtonVariant.primary,
    identifier: 'open-floating-shell',
    onPressed: () => _open(
      context,
      key: 'widgetbook-floating-shell',
      title: 'Floating shell',
      size: _size,
      content: const FloatingShellDemo(state: ShellDemoState.slots),
    ),
  );
}

/// Opens Story 11.6's Projects window content over the demo registry in a real dialog window with the app's own
/// spec ([projectsWindowSpec]: 900 × 640, resizable down to 680 × 440), so a reviewer drags it through the narrow
/// header, a Finder folder onto it and presses Add directory for the real folder picker.
class _OpenProjectsWindow extends StatelessWidget {
  const _OpenProjectsWindow();

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open the Projects window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-projects-window',
    onPressed: () => _open(
      context,
      key: 'widgetbook-projects-window',
      title: projectsWindowTitle,
      dialog: projectsWindowSpec,
      content: const DemoProjectsWindow(),
    ),
  );
}

/// Opens Story 11.7's Settings window over the demo project (a temp-folder settings store, an in-memory jj config,
/// two remotes, a few bookmarks) in a real dialog window with the app's spec ([settingsWindowSpec]: 620 wide, the
/// height following the tab up to 740) on the content-sized root.
class _OpenSettingsWindow extends StatelessWidget {
  const _OpenSettingsWindow();

  static const _key = 'widgetbook-settings';

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open the Settings window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-settings-window',
    onPressed: () {
      final AppWindows windows = CatalogueWindows.of(context);
      _open(
        context,
        key: _key,
        title: platformStrings().settingsTabGeneral,
        dialog: settingsWindowSpec,
        content: _DemoSettingsWindow(windows: windows, windowKey: _key),
      );
    },
  );
}

/// The Settings window's repository reads over fixed demo answers.
class _DemoSettingsReads implements SettingsRepoReads {
  @override
  Future<List<String>> remoteNames() async => const <String>['origin', 'upstream'];

  @override
  Future<List<String>> defaultFetchRemotes() async => const <String>['origin'];

  @override
  Future<List<String>> defaultPushRemotes() async => const <String>['origin'];

  @override
  Future<List<String>> remoteBookmarks(String remote) async => const <String>['main', 'release/1.5.x'];

  @override
  Future<List<String>> localBookmarks() async => const <String>['develop', 'main', 'release/1.1.0-rc1'];

  @override
  Future<RevsetCounts> revsetCounts(List<String> expressions, {required int cap}) async => RevsetCounts(
    <RevsetCount>[for (final _ in expressions) const RevsetCount(n: 14, capped: false, error: null)],
    const <ZanshinWarning>[],
  );

  static RevsetMember _tag(String name) => RevsetMember(
    refs: <TopologyRef>[
      TopologyRef(
        node: 0,
        kind: TopologyRefKind.tag,
        name: name,
        remote: null,
        synced: true,
        conflicted: false,
        tracked: false,
      ),
    ],
  );

  // The DS card's matches: tags v1.0.0 and v1.4.2, release/1.5.x@origin untracked, heads main · v1.0.0 · v1.4.2.
  @override
  Future<List<RevsetMember>> revsetMembers(String revset) async => switch (revset) {
    'tags()' => <RevsetMember>[_tag('v1.0.0'), _tag('v1.4.2')],
    'untracked_remote_bookmarks()' => const <RevsetMember>[
      RevsetMember(
        refs: <TopologyRef>[
          TopologyRef(
            node: 0,
            kind: TopologyRefKind.bookmark,
            name: 'release/1.5.x',
            remote: 'origin',
            synced: false,
            conflicted: false,
            tracked: false,
          ),
        ],
      ),
    ],
    'immutable_heads()' => <RevsetMember>[
      const RevsetMember(
        refs: <TopologyRef>[
          TopologyRef(
            node: 0,
            kind: TopologyRefKind.bookmark,
            name: 'main',
            remote: null,
            synced: true,
            conflicted: false,
            tracked: false,
          ),
        ],
      ),
      _tag('v1.0.0'),
      _tag('v1.4.2'),
    ],
    _ => const <RevsetMember>[],
  };
}

/// The Settings window over the demo project.
class _DemoSettingsWindow extends StatefulWidget {
  const _DemoSettingsWindow({required this.windows, required this.windowKey});

  final AppWindows windows;
  final String windowKey;

  @override
  State<_DemoSettingsWindow> createState() => _DemoSettingsWindowState();
}

class _DemoSettingsWindowState extends State<_DemoSettingsWindow> {
  late final Directory _dir = Directory.systemTemp.createTempSync('zanshin_catalogue_settings');
  late final String _home = _dir.resolveSymbolicLinksSync();
  final _state = SettingsWindowState();
  final _graph = ValueNotifier<GraphMenuBinding?>(null);
  SettingsStore? _store;
  ProjectSession? _session;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    unawaited(
      store
          .update((settings) => settings.copyWith(projects: demoProjectsSettings(_home)))
          .onError<FileSystemException>((_, _) {}),
    );
    if (!mounted) {
      return;
    }
    final session = ProjectSession(registry: ProjectRegistry(store), repos: DemoProjectRepos(_home));
    setState(() {
      _store = store;
      _session = session;
    });
    await session.open(demoOpenProject(_home));
  }

  @override
  void dispose() {
    _session?.dispose();
    _graph.dispose();
    _state.dispose();
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A write still under way; the temp folder goes with the system's clean-up.
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsStore? store = _store;
    final ProjectSession? session = _session;
    if (store == null || session == null) {
      return const SizedBox(width: 620, height: 120);
    }
    return SettingsWindow(
      state: _state,
      windows: widget.windows,
      windowKey: widget.windowKey,
      store: store,
      environment: DemoProjectsEnvironment(_home),
      session: session,
      graph: _graph,
      setThemeMode: (mode) => store.update((settings) => settings.copyWith.appearance(themeMode: mode)),
      readsOf: (_) => _DemoSettingsReads(),
    );
  }
}

/// Opens Story 10.22's jj log Configurations window over two demo configurations (a temp-folder settings store, no
/// project: no count, `mine()` without an email) in a real dialog window with the app's spec
/// ([revsetConfigsWindowSpec]: 880 × 580, down to 820 × 460, floating while active).
class _OpenRevsetConfigsWindow extends StatelessWidget {
  const _OpenRevsetConfigsWindow();

  static const _key = 'widgetbook-revset-configs';

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open the Configurations window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-revset-configs-window',
    onPressed: () {
      final AppWindows windows = CatalogueWindows.of(context);
      _open(
        context,
        key: _key,
        title: platformStrings().revsetConfigsTitle,
        dialog: revsetConfigsWindowSpec,
        content: _DemoRevsetConfigsWindow(windows: windows, windowKey: _key),
      );
    },
  );
}

/// The Configurations window over a temp-folder settings store holding two demo configurations, bound to a graph on
/// the catalogue's fake sources so its preview counts ("N of M changes match").
class _DemoRevsetConfigsWindow extends StatefulWidget {
  const _DemoRevsetConfigsWindow({required this.windows, required this.windowKey});

  final AppWindows windows;
  final String windowKey;

  @override
  State<_DemoRevsetConfigsWindow> createState() => _DemoRevsetConfigsWindowState();
}

class _DemoRevsetConfigsWindowState extends State<_DemoRevsetConfigsWindow> {
  late final Directory _dir = Directory.systemTemp.createTempSync('zanshin_catalogue_configurations');
  final _graph = ValueNotifier<GraphMenuBinding?>(null);
  SettingsStore? _store;
  GraphViewModel? _model;
  GraphSearchController? _search;
  GraphPreferences? _preferences;

  static const _settings = GraphSettings(
    revsetConfigs: <RevsetConfiguration>[
      RevsetConfiguration(
        id: 'c-mine',
        name: 'My open work',
        rules: <RevsetRule>[
          RevsetRule(fn: RevsetRuleFunction.mine),
          RevsetRule(fn: RevsetRuleFunction.files, mode: RevsetRuleMode.glob, value: '*.lock', not: true),
        ],
      ),
      RevsetConfiguration(
        id: 'c-lena',
        name: 'Lena or fixes',
        op: RevsetCombine.or,
        rules: <RevsetRule>[
          RevsetRule(fn: RevsetRuleFunction.author, value: 'lena', ci: true),
          RevsetRule(fn: RevsetRuleFunction.subject, mode: RevsetRuleMode.regex, value: '^fix'),
        ],
      ),
      RevsetConfiguration(
        id: 'c-stack',
        name: 'My stack, no conflicts',
        rules: <RevsetRule>[
          RevsetRule(fn: RevsetRuleFunction.revset, value: 'trunk()..@'),
          RevsetRule(fn: RevsetRuleFunction.revset, value: 'conflicts()', not: true),
        ],
      ),
    ],
    revsetDefault: 'c-mine',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    // The demo's writes go to the temp folder; a failed one changes nothing the demo shows.
    unawaited(store.update((s) => s.copyWith(graph: _settings)).onError<FileSystemException>((_, _) {}));
    if (!mounted) {
      return;
    }
    // The graph demo's wiring (graph.dart, "Floating shell / Controls"), without its verbs and inspector.
    final model = GraphViewModel();
    final search = GraphSearchController(
      model: model,
      source: FakeGraphSearchSource(
        () => requestedLayout(
          'design-all',
          GraphRequest(
            revset: 'all()',
            prioritize: FakeGraphSource.defaults.logGraphPrioritize,
            shortPrefixes: FakeGraphSource.defaults.shortPrefixes,
            anchors: const <String>[],
            utcOffsetMin: 0,
          ),
        ),
      ),
      store: MemoryGraphSearchStore(),
    );
    // The window shows no graph; the preview's "of M" is the layout's `|all()|`, which the recordings do not carry.
    const options = GraphViewOptions();
    final (String input, String output) =
        graphRecordings['design-default ${options.layout.name} ${options.laneOrder.name}']!;
    final layout = RecordedGraphLayout.fromSpec(
      input,
      output,
      operationId: catalogueOperationId,
      totalCount: recordedLayout('design-all', options, inlineContent: false).nodeCount,
    );
    final preferences = GraphPreferences(store)..init(model, FakeGraphSource((_) => layout), revset: search.revset);
    setState(() {
      _store = store;
      _model = model;
      _search = search;
      _preferences = preferences;
      _graph.value = GraphMenuBinding(model: model, preferences: preferences, search: search);
    });
  }

  @override
  void dispose() {
    _graph.value = null;
    _preferences?.dispose();
    _search?.dispose();
    _model?.dispose();
    _graph.dispose();
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A write still under way; the temp folder goes with the system's clean-up.
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsStore? store = _store;
    return store == null
        ? const SizedBox.expand()
        : RevsetConfigsWindow(
            settings: store,
            graph: _graph,
            windows: widget.windows,
            windowKey: widget.windowKey,
            openUrl: (_) async {},
          );
  }
}
