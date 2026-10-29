// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/projects/project_status_style.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show ProjectStatus;
import 'package:zanshin_ui/zanshin_ui.dart';

/// The "Materials" folder: each Story 11.2 material over a busy canvas inside one [BackdropGroup], so its blur, sheen
/// and edge read against something.
final materialsFolder = WidgetbookFolder(
  name: 'Materials',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Island',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Shapes', builder: (context) => _overCanvas(const _Islands())),
        // Story 11.3: glass faded through ZsFade keeps its blur (an Opacity above it would drop it).
        WidgetbookUseCase(
          name: 'Fade',
          builder: (context) => _overCanvas(
            ZsFade(
              opacity: context.knobs.double.slider(label: 'opacity', initialValue: .5, max: 1, divisions: 20),
              child: const _Islands(),
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Glass',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Toast and minimap', builder: (context) => _overCanvas(const _Glass())),
      ],
    ),
    WidgetbookComponent(
      name: 'Menu material',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'With and without arrow', builder: (context) => _overCanvas(const _Menus())),
      ],
    ),
    WidgetbookComponent(
      name: 'Sheet',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Over islands', builder: _sheet),
      ],
    ),
    WidgetbookComponent(
      name: 'Window fill',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Fill',
          builder: (context) => const ZsWindowFill(child: Center(child: Text('ZsWindowFill'))),
        ),
      ],
    ),
    // Story 11.4: the project window's canvas, the two static shaders, full bleed (no islands over it).
    WidgetbookComponent(
      name: 'Canvas',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Window canvas', builder: (context) => const ZsCanvas()),
      ],
    ),
    // Story 11.15: the chip a dragged Projects row carries, over the window fill.
    WidgetbookComponent(
      name: 'Drag ghost',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Kinds',
          builder: (context) => const ZsWindowFill(child: _Ghosts()),
        ),
      ],
    ),
  ],
);

/// A project and a group with a target, and a project with the hint (DS components/overlays/DragGhost.prompt.md:7).
class _Ghosts extends StatelessWidget {
  const _Ghosts();

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 40,
        children: <Widget>[
          ZsDragGhost(
            kind: ZsDragGhostKind.project,
            label: 'dotfiles',
            dot: ProjectStatus.clean.colorIn(colors),
            target: 'Into Backend',
          ),
          const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Mobile', target: 'To the top level'),
          ZsDragGhost(
            kind: ZsDragGhostKind.project,
            label: 'workers',
            dot: ProjectStatus.conflict.colorIn(colors),
            hint: 'Drop between rows or on a group',
          ),
        ],
      ),
    );
  }
}

/// [child] over the busy canvas, in a [BackdropGroup] (11.3's per-window group).
Widget _overCanvas(Widget child) => BackdropGroup(
  child: Stack(
    fit: StackFit.expand,
    children: <Widget>[const _BusyCanvas(), child],
  ),
);

/// Stripes in the semantic colours under lines of text: what a blur visibly softens.
class _BusyCanvas extends StatelessWidget {
  const _BusyCanvas();

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CustomPaint(painter: _Stripes(<Color>[colors.accentLine, colors.add, colors.rem, colors.warn, colors.gold])),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              List<String>.filled(40, 'jj new main — jj squash --into @- — jj git push --bookmark feat/x').join('  '),
              style: ZsType.code.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stripes extends CustomPainter {
  _Stripes(this.colors);

  final List<Color> colors;

  /// A stripe's width and the gap after it.
  static const double _band = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = _band;
    var i = 0;
    for (double x = -size.height; x < size.width; x += _band * 3) {
      paint.color = colors[i++ % colors.length].withValues(alpha: .55);
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => oldDelegate.colors != colors;
}

class _Islands extends StatelessWidget {
  const _Islands();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: <Widget>[
        ZsIsland(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: ZsIslandShape.bar.gap,
            children: <Widget>[
              ZsIconButton(icon: ZI.undo, label: 'Undo', onPressed: () {}),
              ZsIconButton(icon: ZI.fetch, label: 'Fetch', onPressed: () {}),
              const ZsIslandSeparator(),
              ZsIconButton(icon: ZI.push, label: 'Push', onPressed: () {}),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: <Widget>[
              ZsIsland(
                shape: ZsIslandShape.rail,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: ZsIslandShape.rail.gap,
                  children: <Widget>[
                    ZsIconButton(icon: ZI.folder, label: 'Projects', size: ZsIconButtonSize.lg, onPressed: () {}),
                    ZsIconButton(icon: ZI.history, label: 'Operations', size: ZsIconButtonSize.lg, onPressed: () {}),
                  ],
                ),
              ),
              const SizedBox(
                width: 280,
                height: 220,
                child: ZsIsland(
                  shape: ZsIslandShape.panel,
                  child: Padding(padding: EdgeInsets.all(14), child: Text('Panel: strong glass, clipped')),
                ),
              ),
              const ZsIsland(
                shape: ZsIslandShape.free,
                child: Padding(padding: EdgeInsets.all(14), child: Text('Free island')),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Glass extends StatelessWidget {
  const _Glass();

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 24,
        children: <Widget>[
          ZsGlass(
            fill: ZsGlassFill.strong,
            radius: metrics.radiusPill,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: const Text('Toast: pushed feat/onboarding to origin'),
          ),
          ZsGlass(
            fill: ZsGlassFill.strong,
            blur: ZsGlassBlur.strong,
            radius: metrics.radiusIsland,
            child: const SizedBox(width: 180, height: 120, child: Center(child: Text('Minimap'))),
          ),
        ],
      ),
    );
  }
}

class _Menus extends StatelessWidget {
  const _Menus();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 24,
      children: <Widget>[
        SizedBox(
          width: 240,
          child: ZsMenuMaterial(padding: EdgeInsets.all(12), child: Text('Menu material')),
        ),
        SizedBox(
          width: 240,
          child: ZsMenuMaterial(arrow: true, padding: EdgeInsets.all(12), child: Text('With the arrow')),
        ),
      ],
    ),
  );
}

Widget _sheet(BuildContext context) {
  // Each toggle builds a fresh sheet, so its entrance plays again.
  final bool replay = context.knobs.boolean(label: 'replay entrance');
  return _overCanvas(
    Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const _Islands(),
        ZsSheet(
          key: ValueKey<bool>(replay),
          semanticLabel: 'Sheet',
          onCancel: () {},
          width: 420,
          child: const Padding(padding: EdgeInsets.all(20), child: Text('A sheet over the islands and its scrim')),
        ),
      ],
    ),
  );
}
