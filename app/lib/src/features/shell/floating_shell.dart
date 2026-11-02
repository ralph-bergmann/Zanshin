// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'calm_controller.dart';
import 'graph_insets.dart';
import 'pinned_panel.dart';
import 'rail.dart';
import 'rail_preview.dart';
import 'shell_controller.dart';
import 'shell_layout.dart';
import 'shell_scope.dart';
import 'top_bar.dart';

/// The project window's floating overlay host (epics.md Story 11.3; DS readme.md:84, :100; ui_kits/desktop/kit.css):
/// the graph fills the window and every control floats over it on glass islands, in named slots the other stories
/// fill. It owns no graph semantics.
///
/// **Layers**, bottom to top: [canvas] (a plain `--canvas-base` fill for a host that passes none; the project window
/// passes `ZsCanvas`), [graph] inside the calm-scrolling listener, [barRow] over the bar's row (`0` to
/// `--chrome-top`; the window's drag region, Story 11.4), the chrome (`--z-chrome`: the top bar
/// Place · View · Action, the inspector, the minimap, the rail with its pinned panel, edge and flyout, the stale
/// notice, the @ pill and the toast) and the rail's preview (`--z-preview`). Sheets, menus and tooltips mount
/// through the window's `Overlay` above. One `BackdropGroup` holds every island; pointer events pass through
/// wherever no island is, so a press below the bar row between islands reaches the graph.
///
/// **Geometry** from 11.1's tokens and the [ShellLayout] width model; the slots read the [GraphInsets] through
/// [ShellScope.insetsOf] and reach the [controller] through [ShellScope.of]. The inspector sits at right 12 with the
/// effective width, the minimap at right 12, both from `--chrome-top` to 12 above the bottom; the stale notice
/// centred at `--chrome-top`; the @ pill and the toast centred on the visible rect, 20 above the bottom (DS
/// ui_kits/desktop/kit.css:167, :169), the pill hidden while a toast shows.
///
/// **Calm scrolling** (decisions 16.4, 16.45; DS tokens/motion.css:63-67; kit.css:177-187). The listener around the
/// canvas and the graph counts wheel scrolling (|dx| + |dy|) and the trackpad's pan (|pan delta|, only while it
/// neither zooms nor rotates), never with ⌃ held. While a phase runs, PLACE, VIEW and ACTION fade and drift −6 px up,
/// the rail and the panels −8 px left, the inspector +16 px right (unless pinned for the phase), the @ pill fades in
/// `--dur-exit`; out on `--dur-calm-out` / `--ease-exit`, back after `--delay-calm-in` over `--dur-calm-in` (fade on
/// `--ease-state`, drift on `--ease-glide`), each drift × `--motion`, the glass faded through [ZsFade]. Groups aside
/// ignore the pointer; the preview closes outright; the toast, the stale notice and the minimap stay — the minimap
/// comes forward while the inspector is aside. VIEW stays while focus is inside it.
///
/// **Keys and the window.** Esc closes the preview, then the flyout (only this window's). F6 moves focus to the
/// toast's first button while a toast shows (Story 10.23; the toast keeps its buttons out of Tab until then), and back
/// to where it was when the toast goes. While the window is not key no preview opens and an open one closes (until
/// 11.12 the window counts as key).
///
/// **What a slot must bring** (Story 11.3 review):
/// - Content that steps aside draws on Zs materials, which fade through [ZsFade]; anything else in a group fades
///   itself with an `Opacity` of [ZsFade.of] (the panel's resize edge does).
/// - The bar's slots report intrinsic widths: the bar measures their max-content with `getMaxIntrinsicWidth`, so a
///   `LayoutBuilder` directly in a bar slot throws.
/// - A slot's menus, popovers, selects and sheets hold calm while open through `ShellScope.of(context).openSurface()`,
///   and its item drags through `startItemDrag()` (the shell sees neither on its own).
/// - The inspector slot is exactly the inspector's effective width, so its resize edge lives here as a sibling
///   (Story 10.8), as `ShellPanels` does for the panel's edge — `ZsResizeEdge(side: left)` at the inspector's left
///   edge, "Inspector width", bound to `ShellLayout.inspectorMax`, `ShellController.inspectorWidth`,
///   `commitInspectorWidth`, `edgeDragStarted`/`edgeDragEnded` and `itemDragging`. The slot open means non-null: the
///   inspector enters and leaves through [ShellPanelMotion] with a 12 px slide from the right; the shell keeps the
///   last one mounted for its exit and removes the edge as the exit starts.
class FloatingShell extends StatefulWidget {
  /// The shell over [controller]; every slot left null stays empty (an empty island in the bar).
  const FloatingShell({
    required this.controller,
    this.railItems = const <ShellRailItem>[],
    this.canvas,
    this.graph,
    this.barRow,
    this.projectCapsule,
    this.view,
    this.syncGroup,
    this.newChange,
    this.inspector,
    this.minimap,
    this.atPill,
    this.toast,
    this.staleNotice,
    super.key,
  });

  /// The shell's state; its owner disposes it.
  final ShellController controller;

  /// The rail's items; none hides the rail.
  final List<ShellRailItem> railItems;

  /// The window canvas; a plain `--canvas-base` fill while null (the project window passes `ZsCanvas`, Story 11.4).
  final Widget? canvas;

  /// The graph view (Epic 10).
  final Widget? graph;

  /// The bar's row, under the islands: the window's drag region (Story 11.4).
  final Widget? barRow;

  /// PLACE: the project capsule island (11.5).
  final Widget? projectCapsule;

  /// VIEW: the View island's content (10.21, 10.7).
  final Widget? view;

  /// ACTION: the sync group island (11.8).
  final Widget? syncGroup;

  /// ACTION: the New change island (10.7).
  final Widget? newChange;

  /// The inspector (10.8), shown while not null.
  final Widget? inspector;

  /// The minimap (10.16).
  final Widget? minimap;

  /// The @ pill (10.6).
  final Widget? atPill;

  /// The toast (10.23).
  final Widget? toast;

  /// The stale-working-copy notice (10.5).
  final Widget? staleNotice;

  /// The drift of the top bar's groups (DS ui_kits/desktop/kit.css:181, `translateY(calc(-6px * var(--motion)))`).
  static const barDrift = Offset(0, -6);

  /// The drift of the rail and the panels (DS ui_kits/desktop/kit.css:182, `translateX(calc(-8px * …))`).
  static const sideDrift = Offset(-8, 0);

  /// The drift of the inspector (DS ui_kits/desktop/kit.css:183, `translateX(calc(16px * …))`).
  static const inspectorDrift = Offset(16, 0);

  /// The inspector's entrance slide and mirrored exit drift, before × `--motion` (epics.md Story 10.8, 2026-10-16
  /// note; DS tokens/motion.css:31).
  static const double inspectorSlide = 12;

  /// The bottom slot's distance from the window's bottom (DS ui_kits/desktop/kit.css:167, :169, `bottom:20px`).
  static const double bottomSlot = 20;

  /// The preview's left edge and its offset from the button's centre: its arrow tip lies 22 below its top (DS
  /// ui_kits/desktop/kit.css:67, `left:76px;transform:translateY(-22px)`).
  static const double previewLeft = 76;
  static const double previewArrowY = 22;

  /// The callout's width (DS components/surfaces/surfaces.css:16, `width:290px`).
  static const double previewWidth = 290;

  @override
  State<FloatingShell> createState() => _FloatingShellState();
}

class _FloatingShellState extends State<FloatingShell> {
  final _viewFocus = FocusNode(debugLabel: 'View island', canRequestFocus: false, skipTraversal: true);
  final _inspectorFocus = FocusNode(debugLabel: 'Inspector', canRequestFocus: false, skipTraversal: true);
  final _bottomFocus = FocusNode(debugLabel: 'Bottom slot', canRequestFocus: false, skipTraversal: true);
  final _escape = FocusNode(debugLabel: 'FloatingShell', skipTraversal: true);

  /// The tap-region group of the rail and the flyout.
  final _railGroup = Object();

  ShellRailItem? _preview;
  Widget? _stale;

  /// The last inspector, kept for its exit.
  Widget? _inspector;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(FloatingShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.calm.decideInspectorPinned = null;
      _attach(widget.controller);
      widget.controller.inactive = ZsAppearance.of(context).inactive;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.controller.inactive = ZsAppearance.of(context).inactive;
  }

  @override
  void dispose() {
    widget.controller.calm.decideInspectorPinned = null;
    _viewFocus.dispose();
    _inspectorFocus.dispose();
    _bottomFocus.dispose();
    _escape.dispose();
    super.dispose();
  }

  void _attach(ShellController controller) {
    controller.calm.decideInspectorPinned = _typingInInspector;
  }

  /// Whether a text field inside the inspector slot has focus (the phase pins the inspector, GV:944-946).
  bool _typingInInspector() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    final BuildContext? context = primary?.context;
    if (context == null || !_inspectorFocus.hasFocus) {
      return false;
    }
    return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.f6) {
      return _focusToast() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    return widget.controller.handleEscape() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// F6 moves to the toast region (DS components/overlays/Toast.prompt.md:15): focus lands on its first button.
  bool _focusToast() {
    if (widget.toast == null) {
      return false;
    }
    for (final FocusNode node in _bottomFocus.descendants) {
      if (node.canRequestFocus) {
        if (!_bottomFocus.hasFocus) {
          _beforeToast = FocusManager.instance.primaryFocus;
        }
        node.requestFocus();
        return true;
      }
    }
    return false;
  }

  /// Where focus was before F6, until it leaves the toast.
  FocusNode? _beforeToast;

  /// Focus leaving the toast because it went (×, its action, the hold) returns to where F6 took it from.
  void _bottomFocusChanged(bool focused) {
    if (focused) {
      return;
    }
    final FocusNode? before = _beforeToast;
    _beforeToast = null;
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (before != null &&
        before.context != null &&
        before.canRequestFocus &&
        (primary == null || primary is FocusScopeNode)) {
      before.requestFocus();
    }
  }

  static bool get _controlHeld => HardwareKeyboard.instance.isControlPressed;

  void _signal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && !_controlHeld) {
      widget.controller.reportUserScroll(event.scrollDelta.dx.abs() + event.scrollDelta.dy.abs());
    }
  }

  void _panZoom(PointerPanZoomUpdateEvent event) {
    if (event.scale == 1 && event.rotation == 0 && !_controlHeld) {
      widget.controller.reportUserScroll(event.panDelta.dx.abs() + event.panDelta.dy.abs());
    }
  }

  ShellRailItem? _item(String? id) {
    for (final ShellRailItem item in widget.railItems) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ShellController controller = widget.controller;
    return BackdropGroup(
      child: Focus(
        focusNode: _escape,
        autofocus: true,
        includeSemantics: false,
        onKeyEvent: _key,
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[controller, controller.calm, _viewFocus]),
            builder: (context, _) => _layers(context, box.biggest),
          ),
        ),
      ),
    );
  }

  Widget _layers(BuildContext context, Size size) {
    final ShellController controller = widget.controller;
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final ShellLayout layout = controller.layoutFor(
      windowWidth: size.width,
      metrics: metrics,
      inspectorOpen: widget.inspector != null,
      minimapShown: widget.minimap != null,
    );
    final CalmPhase phase = controller.calm.value;
    final bool calm = phase.calm;
    final GraphInsets insets = layout.insets;
    final List<ShellRailItem> items = widget.railItems;
    final Widget? graph = widget.graph;
    final Widget? barRow = widget.barRow;
    final Widget? inspector = widget.inspector;
    if (inspector != null) {
      _inspector = inspector;
    }
    final Widget? shownInspector = _inspector;
    final Widget? minimap = widget.minimap;
    final Widget? stale = widget.staleNotice;
    if (stale != null) {
      _stale = stale;
    }
    final Widget? shownStale = _stale;
    final Widget? bottom = widget.toast ?? _bottomPill(calm, motion);

    // Every child is keyed: the conditional ones would otherwise shift the others' elements, and a rail or panel
    // matched to another slot's element loses its state (Story 11.3 review).
    final chrome = <Widget>[
      Positioned(
        key: const ValueKey<String>('shell-bar'),
        left: metrics.chromeFirstX,
        right: metrics.chromeInset,
        top: metrics.chromeBarY,
        height: metrics.chromeH,
        child: ShellTopBar(
          projectCapsule: widget.projectCapsule,
          view: widget.view,
          syncGroup: widget.syncGroup,
          newChange: widget.newChange,
          viewFocus: _viewFocus,
          decorate: (group, child) => _CalmGroup(
            aside: calm && !(group == TopBarGroup.view && _viewFocus.hasFocus),
            drift: FloatingShell.barDrift,
            child: child,
          ),
        ),
      ),
      if (shownInspector != null)
        Positioned(
          key: const ValueKey<String>('shell-inspector'),
          right: metrics.chromeInset,
          top: metrics.chromeTop,
          bottom: metrics.chromeInset,
          width: layout.inspectorWidth,
          child: Focus(
            focusNode: _inspectorFocus,
            includeSemantics: false,
            child: _CalmGroup(
              aside: calm && !phase.inspectorPinned,
              drift: FloatingShell.inspectorDrift,
              child: ZsPresence(
                open: inspector != null,
                exit: motion.durExitLg,
                builder: (context, closing) => ShellPanelMotion(
                  closing: closing,
                  drift: FloatingShell.inspectorSlide,
                  child: shownInspector,
                ),
              ),
            ),
          ),
        ),
      // The edge goes as the exit starts; removing it mid-drag ends the drag (`ZsResizeEdge.dispose`).
      if (inspector != null)
        Positioned(
          key: const ValueKey<String>('shell-inspector-edge'),
          right: metrics.chromeInset + layout.inspectorWidth - (metrics.resizeHit - metrics.resizeHitOut),
          top: metrics.chromeTop + metrics.radiusPanel,
          bottom: metrics.chromeInset + metrics.radiusPanel,
          width: metrics.resizeHit,
          child: _CalmGroup(
            aside: calm && !phase.inspectorPinned,
            drift: FloatingShell.inspectorDrift,
            // Not a material: it fades with the inspector itself, its line and focus ring included (`ZsFade`).
            child: Builder(
              builder: (context) => Opacity(
                opacity: ZsFade.of(context),
                child: ZsResizeEdge(
                  side: ZsResizeSide.left,
                  value: layout.inspectorWidth,
                  min: metrics.inspectorWMin,
                  max: layout.inspectorMax,
                  defaultValue: metrics.inspectorW,
                  label: context.l10n.inspectorWidth,
                  identifier: 'inspector-edge',
                  inert: controller.itemDragging,
                  onChanged: (width) => controller.inspectorWidth = width,
                  onChangeEnd: controller.commitInspectorWidth,
                  onDragStart: controller.edgeDragStarted,
                  onDragEnd: controller.edgeDragEnded,
                ),
              ),
            ),
          ),
        ),
      if (minimap != null)
        Positioned(
          key: const ValueKey<String>('shell-minimap'),
          right: metrics.chromeInset,
          top: metrics.chromeTop,
          bottom: metrics.chromeInset,
          width: metrics.minimapW,
          child: _MinimapMotion(visible: inspector == null || (calm && !phase.inspectorPinned), child: minimap),
        ),
      if (items.isNotEmpty) ...<Widget>[
        Positioned(
          key: const ValueKey<String>('shell-rail'),
          left: metrics.chromeInset,
          top: metrics.chromeTop,
          child: TapRegion(
            groupId: _railGroup,
            child: _CalmGroup(
              aside: calm,
              drift: FloatingShell.sideDrift,
              child: ShellRail(controller: controller, items: items),
            ),
          ),
        ),
        Positioned.fill(
          key: const ValueKey<String>('shell-panels'),
          child: _CalmGroup(
            aside: calm,
            drift: FloatingShell.sideDrift,
            child: ShellPanels(controller: controller, layout: layout, items: items, railGroup: _railGroup),
          ),
        ),
      ],
      if (shownStale != null)
        Positioned(
          key: const ValueKey<String>('shell-stale'),
          left: 0,
          right: 0,
          top: metrics.chromeTop,
          child: Center(
            heightFactor: 1,
            child: ZsPresence(
              open: stale != null,
              exit: motion.durExitLg,
              builder: (context, closing) => _FadeMotion(closing: closing, child: shownStale),
            ),
          ),
        ),
      if (bottom != null)
        Positioned(
          key: const ValueKey<String>('shell-bottom'),
          left: insets.left,
          right: insets.right,
          bottom: FloatingShell.bottomSlot,
          child: Focus(
            focusNode: _bottomFocus,
            includeSemantics: false,
            onFocusChange: _bottomFocusChanged,
            child: Center(heightFactor: 1, child: bottom),
          ),
        ),
    ];

    return ShellScope(
      controller: controller,
      layout: layout,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            key: const ValueKey<String>('shell-graph-layer'),
            child: Listener(
              onPointerSignal: _signal,
              onPointerPanZoomUpdate: _panZoom,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  widget.canvas ?? ColoredBox(color: ZsColors.of(context).canvasBase),
                  ?graph,
                ],
              ),
            ),
          ),
          if (barRow != null)
            Positioned(
              key: const ValueKey<String>('shell-bar-row'),
              left: 0,
              right: 0,
              top: 0,
              height: metrics.chromeTop,
              child: barRow,
            ),
          Positioned.fill(
            key: const ValueKey<String>('shell-chrome'),
            child: Stack(fit: StackFit.expand, children: chrome),
          ),
          if (items.isNotEmpty && !calm) _previewLayer(controller, metrics, motion, size, items),
        ],
      ),
    );
  }

  /// The @ pill in the bottom slot: it fades out on `--dur-exit` while calm and returns with the others (DS
  /// ui_kits/desktop/kit.css:185; Claude's proposal for the return); none while a toast shows.
  Widget? _bottomPill(bool calm, ZsMotion motion) {
    final Widget? pill = widget.atPill;
    if (pill == null) {
      return null;
    }
    return _CalmGroup(aside: calm, drift: Offset.zero, outDuration: motion.durExit, child: pill);
  }

  Widget _previewLayer(
    ShellController controller,
    ZsMetrics metrics,
    ZsMotion motion,
    Size size,
    List<ShellRailItem> items,
  ) {
    final ShellRailItem? open = _item(controller.previewId);
    if (open != null) {
      _preview = open;
    }
    final ShellRailItem? shown = _preview;
    if (shown == null || !items.contains(shown)) {
      return const SizedBox.shrink();
    }
    final double top = ShellRail.buttonCentre(metrics, items.indexOf(shown)) - FloatingShell.previewArrowY;
    return Positioned(
      key: const ValueKey<String>('rail-preview'),
      left: FloatingShell.previewLeft,
      top: top,
      width: FloatingShell.previewWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height - metrics.chromeInset - top),
        child: MouseRegion(
          onEnter: (_) => controller.previewEnter(),
          onExit: (_) => controller.previewExit(),
          child: ZsPresence(
            open: open != null,
            exit: motion.durExit,
            builder: (context, closing) => RailPreview(item: shown, closing: closing),
          ),
        ),
      ),
    );
  }
}

/// A group of islands that steps aside while [aside] (calm scrolling): it fades through [ZsFade] and drifts by
/// [drift] × `--motion` — out over [outDuration] (`--dur-calm-out` unless given) on `--ease-exit`, back after
/// `--delay-calm-in` over `--dur-calm-in`, the fade on `--ease-state` and the drift on `--ease-glide` — and ignores
/// the pointer while aside. Each change starts from the value on screen, as a CSS transition does.
class _CalmGroup extends StatelessWidget {
  const _CalmGroup({required this.aside, required this.drift, required this.child, this.outDuration});

  final bool aside;
  final Offset drift;
  final Duration? outDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    final Duration back = motion.delayCalmIn + motion.durCalmIn;
    final double wait = motion.delayCalmIn.inMicroseconds / back.inMicroseconds;
    final double target = aside ? 1 : 0;
    return IgnorePointer(
      ignoring: aside,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: target),
        duration: aside ? outDuration ?? motion.durCalmOut : back,
        curve: aside ? motion.easeExit : Interval(wait, 1, curve: motion.easeState),
        builder: (context, faded, child) => ZsFade(opacity: (1 - faded).clamp(0, 1), child: child!),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: target),
          duration: aside ? motion.durCalmOut : back,
          curve: aside ? motion.easeExit : Interval(wait, 1, curve: motion.easeGlide),
          builder: (context, drifted, child) =>
              Transform.translate(offset: drift * (motion.motion * drifted), child: child),
          child: child,
        ),
      ),
    );
  }
}

/// The minimap's own motion (DS ui_kits/desktop/kit.css:147-148): in, a fade over `--dur-panel` on `--ease-state`
/// and a slide from +18 px × `--motion` over `--dur-slide` on the glide; out, a fade over `--dur-exit-lg` on
/// `--ease-exit` and the slide to +18 px, ignored by the pointer and gone once the slide has ended.
class _MinimapMotion extends StatefulWidget {
  const _MinimapMotion({required this.visible, required this.child});

  /// The slide (DS ui_kits/desktop/kit.css:148, `translateX(calc(18px * var(--motion)))`).
  static const double _slide = 18;

  final bool visible;
  final Widget child;

  @override
  State<_MinimapMotion> createState() => _MinimapMotionState();
}

class _MinimapMotionState extends State<_MinimapMotion> {
  late bool _gone = !widget.visible;

  @override
  void didUpdateWidget(_MinimapMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _gone = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    final bool visible = widget.visible;
    return Offstage(
      offstage: _gone,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: visible ? 1 : 0),
            duration: visible ? motion.durPanel : motion.durExitLg,
            curve: visible ? motion.easeState : motion.easeExit,
            builder: (context, shown, child) => ZsFade(opacity: shown.clamp(0, 1), child: child!),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: visible ? 0 : 1),
              duration: motion.durSlide,
              curve: motion.easeGlide,
              onEnd: () {
                if (!widget.visible) {
                  setState(() => _gone = true);
                }
              },
              builder: (context, slid, child) =>
                  Transform.translate(offset: Offset(_MinimapMotion._slide * motion.motion * slid, 0), child: child),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A fade with no movement through [ZsFade]: in over `--dur-panel` on `--ease-state`, out while [closing] over
/// `--dur-exit-lg` on `--ease-exit` (the stale notice; DS components/overlays/StaleNotice.prompt.md:13; decision
/// 16.40).
class _FadeMotion extends StatefulWidget {
  const _FadeMotion({required this.closing, required this.child});

  final bool closing;
  final Widget child;

  @override
  State<_FadeMotion> createState() => _FadeMotionState();
}

class _FadeMotionState extends State<_FadeMotion> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _run();
    }
  }

  @override
  void didUpdateWidget(_FadeMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      _run();
    }
  }

  void _run() {
    final ZsMotion motion = ZsMotion.of(context);
    if (widget.closing) {
      _controller
        ..reverseDuration = motion.durExitLg
        ..reverse(from: 1);
    } else {
      _controller
        ..duration = motion.durPanel
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    // The exit runs the controller back from 1; flipping its curve keeps the value the remaining opacity.
    final Curve curve = widget.closing ? motion.easeExit.flipped : motion.easeState;
    return IgnorePointer(
      ignoring: widget.closing,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => ZsFade(opacity: curve.transform(_controller.value).clamp(0, 1), child: child!),
        child: widget.child,
      ),
    );
  }
}
