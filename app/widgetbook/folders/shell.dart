// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The "Shell" folder: Story 11.3's floating overlay host, the shell scaled into the use case with a width knob
/// (880–1440; the project window's minimum is 880, decision 16.37) and a full-screen knob. Each use case opens the
/// shell in one state — the hover-only preview and the calm phase included, which Marionette cannot hover or scroll
/// into — over a stand-in scrollable graph; the slots hold demo islands until their stories land.
final shellFolder = WidgetbookFolder(
  name: 'Shell',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Floating shell',
      useCases: <WidgetbookUseCase>[
        for (final ShellDemoState state in ShellDemoState.values)
          WidgetbookUseCase(name: state.label, builder: (context) => _demo(context, state)),
      ],
    ),
  ],
);

Widget _demo(BuildContext context, ShellDemoState state) => FittedBox(
  child: SizedBox(
    width: context.knobs.double.slider(
      label: 'window width',
      initialValue: state == ShellDemoState.flyout ? 1000 : 1440,
      min: 880,
      max: 1440,
      divisions: 56,
    ),
    height: 900,
    child: FloatingShellDemo(
      key: ValueKey<ShellDemoState>(state),
      state: state,
      fullScreen: context.knobs.boolean(label: 'full screen'),
    ),
  ),
);

/// What a [FloatingShellDemo] shows.
enum ShellDemoState {
  /// The bar's grid over demo islands and the rail.
  layout('Layout'),

  /// The rail's hover preview, open on Bookmarks.
  preview('Preview open'),

  /// Bookmarks pinned.
  pinned('Pinned panel'),

  /// The Undo Timeline pinned without room: the flyout, beside the open inspector.
  flyout('Flyout'),

  /// A calm phase, kept running.
  calm('Calm'),

  /// A demo island in every slot.
  slots('Slots');

  const ShellDemoState(this.label);

  /// The use case's name.
  final String label;
}

/// The floating shell in [state] over demo slots, for the Shell folder and the Windows folder's real window.
class FloatingShellDemo extends StatefulWidget {
  /// A demo in [state].
  const FloatingShellDemo({required this.state, this.fullScreen, super.key});

  /// What the demo shows.
  final ShellDemoState state;

  /// Whether the shell lays out as in full screen: the Shell folder's knob sets it; null keeps what the window root
  /// resolved — the Windows folder's real window, whose root follows the window's chrome report.
  final bool? fullScreen;

  @override
  State<FloatingShellDemo> createState() => _FloatingShellDemoState();
}

class _FloatingShellDemoState extends State<FloatingShellDemo> {
  final _controller = ShellController();
  Timer? _scrolling;

  /// The demo's rail items, with the kit's glyphs (DS ui_kits/desktop/chrome.jsx:7-11).
  static const _items = <ShellRailItem>[
    ShellRailItem(
      id: 'bookmarks',
      label: 'Bookmarks',
      icon: ZI.branch,
      count: '4',
      preview: _DemoRows(<String>['main', 'feat/onboarding', 'fix/graph-lanes', 'release/0.4']),
      panel: _DemoRows(<String>['main', 'feat/onboarding', 'fix/graph-lanes', 'release/0.4', 'origin/main']),
    ),
    ShellRailItem(
      id: 'undo',
      label: 'Undo Timeline',
      icon: ZI.undo,
      count: '48 ops',
      preview: _DemoRows(<String>['jj new main', 'jj squash --into @-', 'jj describe -m "Graph lanes"']),
      panel: _DemoRows(<String>['jj new main', 'jj squash --into @-', 'jj describe -m "Graph lanes"', 'jj git fetch']),
    ),
  ];

  @override
  void initState() {
    super.initState();
    switch (widget.state) {
      case ShellDemoState.preview:
        _controller.railEnter('bookmarks');
      case ShellDemoState.pinned:
        _controller.activate('bookmarks');
      case ShellDemoState.flyout:
        // After the first layout, so the controller knows there is no room for the panel.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _controller.activate('undo');
          }
        });
      case ShellDemoState.calm:
        // Claude's proposal: a steady trickle of reported scrolling keeps the phase on while the use case shows.
        _scrolling = Timer.periodic(const Duration(milliseconds: 300), (_) => _controller.reportUserScroll(40));
      case ShellDemoState.layout || ShellDemoState.slots:
        break;
    }
  }

  @override
  void dispose() {
    _scrolling?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ShellDemoState state = widget.state;
    final bool everything = state == ShellDemoState.slots || state == ShellDemoState.calm;
    final bool inspector = everything || state == ShellDemoState.flyout;
    return ZsAppearanceOverride(
      fullScreen: widget.fullScreen,
      child: Builder(
        builder: (context) => ZsRoot(
          appearance: ZsAppearance.of(context),
          child: FloatingShell(
            controller: _controller,
            railItems: _items,
            canvas: const ZsCanvas(),
            graph: const _StandInGraph(),
            projectCapsule: const _DemoIsland(icon: ZI.folder, text: 'zanshin', width: 176),
            view: const _DemoText('View · search and view controls (10.21, 10.7)'),
            syncGroup: const _DemoIsland(icon: ZI.fetch, text: 'Sync', width: 120),
            newChange: const _DemoIsland(icon: ZI.plus, text: 'New change', width: 118),
            inspector: inspector ? const _DemoPanel('Inspector (10.8)') : null,
            minimap: everything ? const _DemoMinimap() : null,
            atPill: everything ? const _DemoPill('@ kmnvxoqp') : null,
            staleNotice: state == ShellDemoState.slots
                ? const _DemoPill('Working copy is stale · jj workspace update-stale')
                : null,
          ),
        ),
      ),
    );
  }
}

/// A stand-in for the graph (10.1): rows of fake cards that scroll, so the glass has something to blur and the
/// wheel something to count.
class _StandInGraph extends StatelessWidget {
  const _StandInGraph();

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final lanes = <Color>[colors.accentLine, colors.add, colors.rem, colors.warn, colors.gold];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(120, 80, 120, 40),
      itemCount: 120,
      itemExtent: 48,
      itemBuilder: (context, i) => Align(
        alignment: Alignment((i % 7 - 3) / 3, 0),
        child: Container(
          width: 240,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: colors.cardSolid,
            border: Border(left: BorderSide(color: lanes[i % lanes.length], width: 3)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'kmnv${i.toRadixString(36)} · change ${i + 1}',
            style: ZsType.cardSubject.copyWith(color: colors.text),
          ),
        ),
      ),
    );
  }
}

class _DemoIsland extends StatelessWidget {
  const _DemoIsland({required this.icon, required this.text, required this.width});

  final String icon;
  final String text;
  final double width;

  @override
  Widget build(BuildContext context) => ZsIsland(
    child: SizedBox(
      width: width,
      child: Row(
        spacing: 8,
        children: <Widget>[
          const SizedBox(width: 4),
          ZanshinIcon(icon, size: ZsIconSize.bar, color: ZsColors.of(context).textMuted),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ),
  );
}

class _DemoText extends StatelessWidget {
  const _DemoText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ZsType.control.copyWith(color: ZsColors.of(context).textMuted),
    ),
  );
}

class _DemoPanel extends StatelessWidget {
  const _DemoPanel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ZsIsland(
    shape: ZsIslandShape.panel,
    child: Center(
      child: Text(text, style: ZsType.panelTitle.copyWith(color: ZsColors.of(context).textMuted)),
    ),
  );
}

class _DemoMinimap extends StatelessWidget {
  const _DemoMinimap();

  @override
  Widget build(BuildContext context) => ZsGlass(
    fill: ZsGlassFill.strong,
    blur: ZsGlassBlur.strong,
    radius: ZsMetrics.of(context).radiusIsland,
    child: const Center(child: Text('Minimap')),
  );
}

class _DemoPill extends StatelessWidget {
  const _DemoPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ZsGlass(
    radius: ZsMetrics.of(context).radiusPill,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Text(text, style: ZsType.control.copyWith(color: ZsColors.of(context).text)),
  );
}

class _DemoRows extends StatelessWidget {
  const _DemoRows(this.rows);

  final List<String> rows;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final String row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(row, style: ZsType.command.copyWith(color: colors.textMuted)),
            ),
        ],
      ),
    );
  }
}
