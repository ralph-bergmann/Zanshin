// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/window_chrome_builder.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../catalogue.dart' show catalogueAppBuilder;
import '../demo_projects_fakes.dart';
import 'shell.dart' show FloatingShellDemo, ShellDemoState;

/// Hands the catalogue's [AppWindows] to the use cases that open real windows.
class CatalogueWindows extends InheritedWidget {
  /// Provides [windows] to [child].
  const CatalogueWindows({required this.windows, required super.child, super.key});

  /// The catalogue process's windows.
  final AppWindows windows;

  /// The nearest windows (read from callbacks; they never change, so nothing depends on them).
  static AppWindows of(BuildContext context) {
    final CatalogueWindows? scope = context.getInheritedWidgetOfExactType<CatalogueWindows>();
    assert(scope != null, 'No CatalogueWindows above the catalogue.');
    return scope!.windows;
  }

  @override
  bool updateShouldNotify(CatalogueWindows oldWidget) => !identical(windows, oldWidget.windows);
}

/// The root of every window the catalogue opens: [catalogueAppBuilder] over [child] with the window's chrome report
/// (Story 11.4), so its root takes the measured traffic-light block and full screen as the app's window root does.
///
/// One [WindowChromeBuilder] per window; the new window is no descendant of the catalogue's, so it takes the
/// [shellTheme] it was opened with.
class CatalogueWindowRoot extends StatelessWidget {
  /// The root of a catalogue window showing [child].
  const CatalogueWindowRoot({required this.shellTheme, required this.child, super.key});

  /// The shell theme as the catalogue had it when the window opened.
  final ShellTheme? shellTheme;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) => ZsShellScope(
    shellTheme: shellTheme,
    child: WindowChromeBuilder(builder: (context, chrome) => catalogueAppBuilder(context, child, chrome: chrome)),
  );
}

/// The "Windows" folder: use cases that open a real window of their own, as the app's dialog windows will.
///
/// Stories 11.12 (window chrome kinds, dialog windows), 11.6 (Projects), 11.7 (Settings) and 10.22 (Push) add their
/// windows here. Each window's builder returns a [CatalogueWindowRoot] over its content.
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
  ],
);

class _OpenWindowFill extends StatelessWidget {
  const _OpenWindowFill();

  /// The window's first size and its smallest.
  static const _size = Size(560, 360);
  static const _constraints = BoxConstraints(minWidth: 320, minHeight: 200);

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open a window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-window-fill',
    onPressed: () {
      // The new window is no descendant of the catalogue's; it takes the shell theme as it is now.
      final ZsShellScope? shell = context.getInheritedWidgetOfExactType<ZsShellScope>();
      unawaited(
        CatalogueWindows.of(context).openOrActivate(
          key: 'widgetbook-window-fill',
          title: 'Window fill',
          size: _size,
          constraints: _constraints,
          builder: (context) => CatalogueWindowRoot(
            shellTheme: shell?.shellTheme,
            child: const ZsWindowFill(child: Center(child: Text('A window on ZsWindowFill'))),
          ),
        ),
      );
    },
  );
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
    onPressed: () {
      final ZsShellScope? shell = context.getInheritedWidgetOfExactType<ZsShellScope>();
      unawaited(
        CatalogueWindows.of(context).openOrActivate(
          key: 'widgetbook-floating-shell',
          title: 'Floating shell',
          size: _size,
          builder: (context) => CatalogueWindowRoot(
            shellTheme: shell?.shellTheme,
            child: const FloatingShellDemo(state: ShellDemoState.slots),
          ),
        ),
      );
    },
  );
}

/// Opens Story 11.6's Projects window content over the demo registry in a real window of 900 × 640, resizable down to
/// the Projects window's 680 × 440 minimum (Window.prompt.md:23), so a reviewer drags it through the narrow header, a
/// Finder folder onto it and presses Add directory for the real folder picker. The dialog window itself (style mask,
/// title, launch, exit rule) is 11.12's.
class _OpenProjectsWindow extends StatelessWidget {
  const _OpenProjectsWindow();

  static const _size = Size(900, 640);
  static const _constraints = BoxConstraints(minWidth: 680, minHeight: 440);

  @override
  Widget build(BuildContext context) => ZsButton(
    label: 'Open the Projects window',
    variant: ZsButtonVariant.primary,
    identifier: 'open-projects-window',
    onPressed: () {
      final ZsShellScope? shell = context.getInheritedWidgetOfExactType<ZsShellScope>();
      unawaited(
        CatalogueWindows.of(context).openOrActivate(
          key: 'widgetbook-projects-window',
          title: 'Projects',
          size: _size,
          constraints: _constraints,
          builder: (context) => CatalogueWindowRoot(shellTheme: shell?.shellTheme, child: const DemoProjectsWindow()),
        ),
      );
    },
  );
}
