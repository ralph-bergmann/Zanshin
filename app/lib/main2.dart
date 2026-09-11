// SPDX-License-Identifier: MIT

// Windowing-API proof of concept: a borderless splash window first, then the
// start window with the project list; a double-click opens a project in its
// own window. Every window except the splash remembers its size and position.
// Not wired into the real boot; `main.dart` is untouched.
// Design: docs/superpowers/specs/2026-09-11-windowing-splash-poc-design.md
//
// The runner must not attach its nib window in this mode (the engine allows
// multi-view only while it has no view yet), so start the app with the
// `--windowing` process argument:
//
//   flutter run -d macos -t lib/main2.dart --dart-entrypoint-args=--windowing
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';

import 'src/features/bootstrap/remembered_window_controller.dart';
import 'src/features/bootstrap/splash_window_controller.dart';
import 'src/features/bootstrap/zanshin_bootstrap.dart' show splashAnimationAsset, splashAnimationSize;

/// Content size of the splash window.
const splashWindowSize = Size(320, 320);

/// First-launch content size of the start and project windows; afterwards the
/// remembered frame wins.
const defaultWindowSize = Size(1200, 800);

/// Smallest content size of the start and project windows.
const minWindowConstraints = BoxConstraints(minWidth: 900, minHeight: 600);

/// Stands in for the real boot (settings, DI graph, worker).
const fakeBootDuration = Duration(seconds: 3);

/// Stands in for the project list until the real one exists.
const demoProjects = <({String name, String path})>[
  (name: 'Zanshin', path: '~/development/projects/privat/Zanshin'),
  (name: 'jj', path: '~/development/projects/privat/jj'),
  (name: 'yaru.dart', path: '~/development/projects/privat/yaru.dart'),
];

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The macOS engine hands the process arguments to `main` too. Without
  // `--windowing` the runner has attached its nib window as the implicit view
  // and the engine refuses further views: say so in that window instead of
  // crashing natively on the first Dart-created one. (An implicit view exists
  // even in headless mode, so it is no indicator.)
  if (!args.contains('--windowing')) {
    runApp(const _MissingWindowingFlag());
    return;
  }
  // The splash has to be part of the very first frame. That warm-up frame is
  // timer-driven; every later frame waits for the display link of an existing
  // view, and the engine only shows a window after its first frame — for the
  // first window of a view-less engine that never happens (verified: the
  // window is created but stays invisible).
  final SplashWindowController splash = await SplashWindowController.create(size: splashWindowSize);
  // WindowManager owns the registry: window content opens further windows
  // through WindowRegistry.of(context), and windows remove themselves.
  runWidget(
    WindowManager(
      initialWindows: <WindowEntry>[
        WindowEntry(
          controller: splash,
          builder: (_) => _SplashFlow(splash: splash),
        ),
      ],
    ),
  );
}

/// Opens the window remembered under [key], or brings it to the front when it
/// is already open. A new window registers itself and removes itself again
/// when destroyed.
Future<void> _openWindow(
  WindowRegistry registry, {
  required String key,
  required String title,
  required WidgetBuilder builder,
}) async {
  for (final WindowEntry entry in registry.windows) {
    if (entry.controller case final RememberedWindowController open when open.key == key) {
      open.activate();
      return;
    }
  }
  final lifecycle = _WindowLifecycle(registry);
  final RememberedWindowController controller = await RememberedWindowController.create(
    key: key,
    size: defaultWindowSize,
    constraints: minWindowConstraints,
    title: title,
    delegate: lifecycle,
  );
  lifecycle.entry = WindowEntry(controller: controller, builder: builder);
  registry.register(lifecycle.entry);
}

/// Ends the process once no window is left: in windowing mode the runner no
/// longer terminates on the last closed window by itself.
void _exitIfNoWindows(WindowRegistry registry) {
  if (registry.windows.isEmpty) {
    unawaited(ServicesBinding.instance.exitApplication(AppExitType.required));
  }
}

/// Unregisters a destroyed window; the last one takes the process with it.
class _WindowLifecycle with WindowControllerDelegate {
  _WindowLifecycle(this.registry);

  final WindowRegistry registry;
  late WindowEntry entry;

  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    registry.unregister(entry);
    _exitIfNoWindows(registry);
  }
}

/// The splash card; runs the boot, then hands over to the start window.
class _SplashFlow extends StatefulWidget {
  const _SplashFlow({required this.splash});

  final SplashWindowController splash;

  @override
  State<_SplashFlow> createState() => _SplashFlowState();
}

class _SplashFlowState extends State<_SplashFlow> {
  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(fakeBootDuration);
    if (!mounted) {
      return;
    }
    final WindowRegistry registry = WindowRegistry.of(context);
    await _openWindow(registry, key: 'start', title: 'Zanshin', builder: (_) => const _StartWindow());

    // The engine shows a window right after its first frame was presented.
    // `endOfFrame` completes when that frame is built and handed over, a few
    // milliseconds earlier, so the 250 ms fade starts while the start window
    // pops up underneath the floating splash. Good enough for the POC; a
    // slow first raster would let the splash fade before the window shows.
    await WidgetsBinding.instance.endOfFrame;
    await widget.splash.fadeOut();
    registry.unregister(registry.windows.firstWhere((entry) => entry.controller == widget.splash));
    widget.splash.destroy();
    // The start window may already have been closed during the fade.
    _exitIfNoWindows(registry);
  }

  @override
  Widget build(BuildContext context) => MediaQuery.fromView(
    // Platform brightness and accessibility flags without a MaterialApp.
    view: View.of(context),
    child: Builder(
      builder: (context) {
        final ThemeData theme = MediaQuery.platformBrightnessOf(context) == Brightness.dark ? yaruDark : yaruLight;
        return DecoratedBox(
          decoration: BoxDecoration(color: theme.scaffoldBackgroundColor, borderRadius: BorderRadius.circular(12)),
          child: Center(
            child: Lottie.asset(
              splashAnimationAsset,
              width: splashAnimationSize,
              height: splashAnimationSize,
              // "Reduce motion": the first frame is the static logo.
              animate: !MediaQuery.disableAnimationsOf(context),
            ),
          ),
        );
      },
    ),
  );
}

/// The start window: the project list. A double-click opens the project in
/// its own window, remembered under the project's path.
class _StartWindow extends StatelessWidget {
  const _StartWindow();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zanshin',
    theme: yaruLight,
    darkTheme: yaruDark,
    home: Scaffold(
      body: ListView(
        children: <Widget>[
          const ListTile(title: Text('Projects'), subtitle: Text('Double-click opens a project in its own window')),
          for (final project in demoProjects)
            GestureDetector(
              onDoubleTap: () => unawaited(
                _openWindow(
                  WindowRegistry.of(context),
                  key: 'project:${project.path}',
                  title: project.name,
                  builder: (_) => _ProjectWindow(project: project),
                ),
              ),
              child: ListTile(title: Text(project.name), subtitle: Text(project.path)),
            ),
        ],
      ),
    ),
  );
}

/// Placeholder for a project's window; shows what the window scope reports.
class _ProjectWindow extends StatelessWidget {
  const _ProjectWindow({required this.project});

  final ({String name, String path}) project;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: project.name,
    theme: yaruLight,
    darkTheme: yaruDark,
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (context) {
            final Size size = WindowScope.contentSizeOf(context);
            return Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: <Widget>[
                Text(project.name, style: Theme.of(context).textTheme.headlineSmall),
                Text(project.path),
                Text('${WindowScope.titleOf(context)} · ${size.width.round()} × ${size.height.round()}'),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// Rendered into the runner's own window when `--windowing` is missing.
class _MissingWindowingFlag extends StatelessWidget {
  const _MissingWindowingFlag();

  @override
  Widget build(BuildContext context) => const Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: Color(0xFF202020),
      child: Center(
        child: Text(
          'main2.dart needs the runner in windowing mode:\n\n'
          'flutter run -d macos -t lib/main2.dart --dart-entrypoint-args=--windowing',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFFEEEEEE), fontSize: 14),
        ),
      ),
    ),
  );
}
