// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../catalogue.dart' show catalogueAppBuilder;
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

/// The "Windows" folder: use cases that open a real window of their own, as the app's dialog windows will.
///
/// Stories 11.12 (window chrome kinds, dialog windows), 11.6 (Settings), 11.7 (Projects) and 10.22 (Push) add their
/// windows here.
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
          builder: (context) => ZsShellScope(
            shellTheme: shell?.shellTheme,
            child: Builder(
              builder: (context) => catalogueAppBuilder(
                context,
                const ZsWindowFill(child: Center(child: Text('A window on ZsWindowFill'))),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Opens Story 11.3's floating shell with a demo island in every slot in a real 1440 × 900 window, resizable down to
/// the project window's 880 × 560 minimum (decision 16.37), so a reviewer drags it through the collapse widths.
class _OpenFloatingShell extends StatelessWidget {
  const _OpenFloatingShell();

  static const _size = Size(1440, 900);
  static const _constraints = BoxConstraints(minWidth: 880, minHeight: 560);

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
          constraints: _constraints,
          builder: (context) => ZsShellScope(
            shellTheme: shell?.shellTheme,
            child: Builder(
              builder: (context) => catalogueAppBuilder(context, const FloatingShellDemo(state: ShellDemoState.slots)),
            ),
          ),
        ),
      );
    },
  );
}
