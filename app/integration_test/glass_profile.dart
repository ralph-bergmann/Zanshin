// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/scheduler.dart';
// WHY: the windowing API is experimental and `@internal` (flutter#30701); the app's mains use it the same way.
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin/src/features/graph/graph_controls.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/sync/sync_island.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_core/zanshin_core.dart'
    show
        ActionOutcome,
        ActionStatus,
        Change,
        ChangeActions,
        ConflictState,
        Diff,
        FileChange,
        ShowEntry,
        Signature,
        SquashPlan;
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../widgetbook/catalogue.dart' show catalogueAppBuilder;
import '../widgetbook/folders/projects.dart' show demoCapsule;
import '../widgetbook/graph/fake_graph_source.dart';
import '../widgetbook/graph/synthetic_layout.dart';

/// `--dart-define=GLASS=off` paints every island solid (Reduce transparency: no `BackdropFilter`, DS
/// tokens/transparency.css); anything else keeps the glass.
const _glass = String.fromEnvironment('GLASS', defaultValue: 'on') != 'off';

/// The scripted scroll: [_distance] px down over [_leg], then back over [_leg], linear.
const _distance = 20000.0;
const _leg = Duration(seconds: 5);

/// The glass profile harness (deferred-work.md, "The cost of glass"; epics.md Story 11.2 design status (a)): the
/// floating shell over a synthetic 10k graph with its islands open (PLACE, VIEW, ACTION, the rail, the inspector; the
/// minimap does not exist yet), on the catalogue's fakes — never a real repo. It scrolls a fixed path, records every
/// frame's build and raster time, prints one `GLASS_PROFILE {json}` line and exits. Not a test and not in the gate:
///
/// `flutter run --profile -d macos -t integration_test/glass_profile.dart --dart-define=GLASS=on|off` from `app/`.
///
/// The scroll is programmatic, so calm scrolling never sends the islands aside: every island stays on screen, the
/// glass's worst case.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final IconRegistry registry = await IconRegistry.load();
  // ignore: invalid_use_of_internal_member
  final WindowEntry entry = await AppWindows().create(
    key: 'glass-profile',
    title: 'Glass profile (${_glass ? 'glass' : 'solid'})',
    size: const Size(1440, 900),
    builder: (context) => ZsAppearanceOverride(
      theme: ZsTheme.night,
      reduceTransparency: !_glass,
      child: Builder(builder: (context) => catalogueAppBuilder(context, const _Scene())),
    ),
  );
  runWidget(
    IconRegistryScope(
      registry: registry,
      // ignore: invalid_use_of_internal_member
      child: WindowManager(initialWindows: <WindowEntry>[entry]),
    ),
  );
}

class _Scene extends StatefulWidget {
  const _Scene();

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> {
  final Directory _dir = Directory.systemTemp.createTempSync('zanshin_glass_profile');
  final RecordedGraphLayout _layout = syntheticLayout(10000);
  late final _source = FakeGraphSource((_) => _layout);
  final _model = GraphViewModel();
  final _shell = ShellController();
  final GlobalKey _graph = GlobalKey();
  GraphPreferences? _preferences;
  InspectorViewModel? _inspector;

  static const _rail = <ShellRailItem>[
    ShellRailItem(id: 'bookmarks', label: 'Bookmarks', icon: ZI.branch, preview: Text('main'), panel: Text('main')),
    ShellRailItem(id: 'undo', label: 'Undo Timeline', icon: ZI.undo, preview: Text('jj new'), panel: Text('jj new')),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    _model.addListener(_selectFirst);
    setState(() {
      _preferences = GraphPreferences(store)..init(_model, _source);
      _inspector = InspectorViewModel(
        graph: _model,
        details: _Details(_model),
        // A path outside the registry: the marks live in the temp settings file.
        viewed: ProjectViewedStore(store, '/glass-profile'),
        settings: store,
      );
    });
  }

  /// Once the layout landed, selects its first mutable change other than @ (the inspector opens), then measures.
  void _selectFirst() {
    final GraphLayout? layout = _model.layout;
    if (layout == null) {
      return;
    }
    _model.removeListener(_selectFirst);
    for (var node = 0; node < layout.nodeCount; node++) {
      if (node != layout.workingCopyIndex && node != layout.rootIndex && !layout.isImmutable(node)) {
        _model.select(layout.keyOf(node));
        break;
      }
    }
    unawaited(_measure());
  }

  Future<void> _measure() async {
    // Settle: the inspector's entrance, the first content, shader warm-up.
    await Future<void>.delayed(const Duration(seconds: 3));
    final ScrollPosition position = _verticalPosition();
    final double start = position.pixels;
    final timings = <FrameTiming>[];
    void record(List<FrameTiming> frames) => timings.addAll(frames);
    SchedulerBinding.instance.addTimingsCallback(record);
    await position.animateTo(start + _distance, duration: _leg, curve: Curves.linear);
    await position.animateTo(start, duration: _leg, curve: Curves.linear);
    // Timings are reported in batches; let the last one arrive.
    await Future<void>.delayed(const Duration(seconds: 1));
    SchedulerBinding.instance.removeTimingsCallback(record);
    final report = <String, Object?>{
      'glass': _glass,
      'refreshRate': PlatformDispatcher.instance.displays.map((display) => display.refreshRate).toList(),
      'scrolled': position.maxScrollExtent < start + _distance ? position.maxScrollExtent - start : _distance,
      'frames': timings.length,
      'build': _stats([for (final FrameTiming t in timings) t.buildDuration]),
      'raster': _stats([for (final FrameTiming t in timings) t.rasterDuration]),
    };
    // ignore: avoid_print
    print('GLASS_PROFILE ${jsonEncode(report)}');
    _dir.deleteSync(recursive: true);
    exit(0);
  }

  /// The graph's vertical scroll position (the first vertical `Scrollable` below the graph).
  ScrollPosition _verticalPosition() {
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) {
        return;
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        final ScrollPosition position = (element.state as ScrollableState).position;
        if (position.axis == Axis.vertical) {
          found = position;
          return;
        }
      }
      element.visitChildren(visit);
    }

    (_graph.currentContext! as Element).visitChildren(visit);
    return found!;
  }

  @override
  Widget build(BuildContext context) {
    final GraphPreferences? preferences = _preferences;
    final InspectorViewModel? inspector = _inspector;
    if (preferences == null || inspector == null) {
      return const ZsCanvas();
    }
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) => FloatingShell(
        controller: _shell,
        railItems: _rail,
        canvas: const ZsCanvas(),
        graph: KeyedSubtree(
          key: _graph,
          child: ListenableBuilder(
            listenable: preferences,
            builder: (context, _) => GraphView(model: _model, options: preferences.options),
          ),
        ),
        projectCapsule: demoCapsule(),
        view: GraphViewControls(model: _model, preferences: preferences),
        syncGroup: SyncIsland(onReload: _model.reload),
        newChange: NewChangeButton(model: _model),
        inspector: GraphView.inspector(inspector),
        atPill: GraphView.atPill(_model),
      ),
    );
  }
}

/// Milliseconds: average, p90, p99, worst, and the share of frames over 16.7 ms (60 Hz) and 8.3 ms (120 Hz).
Map<String, double> _stats(List<Duration> durations) {
  if (durations.isEmpty) {
    return const <String, double>{};
  }
  final ms = <double>[for (final Duration d in durations) d.inMicroseconds / 1000]..sort();
  double percentile(double p) => ms[((ms.length - 1) * p).round()];
  double share(double budget) => ms.where((value) => value > budget).length / ms.length;
  return <String, double>{
    'avg': ms.reduce((a, b) => a + b) / ms.length,
    'p90': percentile(.9),
    'p99': percentile(.99),
    'max': ms.last,
    'over16_7': share(1000 / 60),
    'over8_3': share(1000 / 120),
  };
}

/// The inspector's reads: the change with no files, every verb available.
class _Details implements GraphDetails {
  _Details(this._model);

  final GraphViewModel _model;

  static const _nobody = Signature(name: 'Ada', email: 'ada@example.com', timestampMillis: 0, tzOffsetMinutes: 0);

  static const _available = ActionOutcome(
    status: ActionStatus.available,
    refusal: null,
    combinedDescriptionNeeded: false,
    allowBackwardsNeeded: false,
  );

  @override
  Future<ShowEntry> show(String commitId) async {
    final GraphLayout layout = _model.layout!;
    final int node = List<int>.generate(layout.nodeCount, (i) => i).firstWhere((i) => layout.commitIdOf(i) == commitId);
    return ShowEntry(
      change: Change(
        id: layout.changeIdOf(node),
        commitId: commitId,
        parents: const <String>[],
        description: 'Profile the glass\n\nWhy: the islands blur the graph on every frame.\n',
        author: _nobody,
        committer: _nobody,
        isSigned: false,
        conflict: ConflictState.clean,
        conflictedPaths: const <String>[],
        isAnonymous: false,
        divergent: false,
      ),
      fileChanges: const <FileChange>[],
    );
  }

  @override
  Future<ChangeActions> changeActions(String changeId) async => const ChangeActions(
    newOnto: _available,
    newInsertAfter: _available,
    newInsertBefore: _available,
    edit: _available,
    describe: _available,
    squashIntoParent: _available,
    abandon: _available,
  );

  @override
  Future<Diff> diff(String commitId, {List<String> paths = const [], bool summary = false}) async =>
      Diff(files: const [], operationId: 'op', commitIds: <String>[commitId]);

  @override
  Future<SquashPlan> squashPlan(String changeId) async => const SquashPlan(combinedDescription: null);
}
