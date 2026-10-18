// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/window_chrome_builder.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../catalogue.dart' show catalogueAppBuilder;
import '../demo_projects_fakes.dart';
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
    this.sizeToContent = false,
    super.key,
  });

  /// The window's key.
  final String windowKey;

  /// Which window is key.
  final ActiveWindowTracker tracker;

  /// The shell theme as the catalogue had it when the window opened.
  final ShellTheme? shellTheme;

  /// Whether the window is sized to its content.
  final bool sizeToContent;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) => ZsShellScope(
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
