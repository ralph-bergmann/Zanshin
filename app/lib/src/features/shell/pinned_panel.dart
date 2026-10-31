// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'shell_controller.dart';
import 'shell_layout.dart';

/// The pinned-panel host (epics.md Story 11.3 items 6 and 11; DS ui_kits/desktop/kit.css:82-87; chrome.jsx:164-166;
/// decisions 16.23, 16.40): the pinned item's panel, its resize edge and the rail's flyout, as one full-window layer
/// the shell moves aside as a group while the graph scrolls.
///
/// **Panel.** At (`--chrome-left`, `--chrome-top`), 12 above the bottom, the layout's effective panel width; it
/// enters with a fade over `--dur-panel` and an 8 px slide from the left × `--motion` on the glide curve, and leaves
/// with a fade and the mirrored 8 px drift × `--motion` over `--dur-exit-lg` on `--ease-exit`, faded through
/// [ZsFade]. Switching the pin replaces the panel and replays the entrance. A collapsed panel shows nothing: no
/// panel, no edge.
///
/// **Edge.** A [ZsResizeEdge] on the panel's right side: 3 over the panel, 7 in the gap, along the straight part of
/// the edge (the `--radius-panel` corners left out), labelled "Panel width", a Tab stop after the panel's own
/// controls; inert during item drags.
///
/// **Flyout** (Claude's proposal; decision 16.23). While the pinned panel has no room, the controller can show it as
/// the rail's temporary flyout: the same panel at the remembered width clamped to 240–440, beside the rail, over the
/// graph, with no edge, in a backdrop group of its own (it may overlap the inspector) and a [TapRegion] in
/// [railGroup], so a tap outside it and the rail closes it.
class ShellPanels extends StatefulWidget {
  /// The panels of [items] for [controller]'s pin in [layout].
  const ShellPanels({
    required this.controller,
    required this.layout,
    required this.items,
    required this.railGroup,
    super.key,
  });

  /// The shell's controller.
  final ShellController controller;

  /// The shell's current layout.
  final ShellLayout layout;

  /// The rail's items.
  final List<ShellRailItem> items;

  /// The tap-region group the rail shares with the flyout.
  final Object railGroup;

  @override
  State<ShellPanels> createState() => _ShellPanelsState();
}

class _ShellPanelsState extends State<ShellPanels> {
  /// The item the panel showed last, kept for its exit.
  ShellRailItem? _panel;

  /// The item the flyout showed last, kept for its exit.
  ShellRailItem? _flyout;

  ShellRailItem? _item(String? id) {
    for (final ShellRailItem item in widget.items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final ShellController controller = widget.controller;
    final ShellLayout layout = widget.layout;
    final ShellRailItem? pinned = _item(controller.pinnedId);
    final bool panelShown = pinned != null && !layout.collapsed;
    final bool flyoutShown = pinned != null && layout.collapsed && controller.flyoutOpen;
    if (panelShown) {
      _panel = pinned;
    }
    if (flyoutShown) {
      _flyout = pinned;
    }
    final ShellRailItem? panel = _panel;
    final ShellRailItem? flyout = _flyout;
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Keyed: the edge comes and goes between the panel and the flyout (Story 11.3 review).
          if (panel != null)
            Positioned(
              key: const ValueKey<String>('panel'),
              left: metrics.chromeLeft,
              top: metrics.chromeTop,
              bottom: metrics.chromeInset,
              width: layout.panelWidth,
              child: ZsPresence(
                open: panelShown,
                exit: motion.durExitLg,
                builder: (context, closing) => ShellPanelMotion(
                  key: ValueKey<String>(panel.id),
                  closing: closing,
                  child: PinnedPanel(item: panel, onClose: controller.unpin),
                ),
              ),
            ),
          if (panelShown)
            Positioned(
              key: const ValueKey<String>('panel-edge'),
              left: metrics.chromeLeft + layout.panelWidth - (metrics.resizeHit - metrics.resizeHitOut),
              top: metrics.chromeTop + metrics.radiusPanel,
              bottom: metrics.chromeInset + metrics.radiusPanel,
              width: metrics.resizeHit,
              // Not a material: it fades with its group itself, its line and focus ring included (`ZsFade`).
              child: Opacity(
                opacity: ZsFade.of(context),
                child: ZsResizeEdge(
                  side: ZsResizeSide.right,
                  value: layout.panelWidth,
                  min: metrics.panelWMin,
                  max: layout.panelMax,
                  defaultValue: metrics.panelW,
                  label: context.l10n.panelWidth,
                  identifier: 'panel-edge',
                  inert: controller.itemDragging,
                  onChanged: (width) => controller.panelWidth = width,
                  onChangeEnd: controller.commitPanelWidth,
                  onDragStart: controller.edgeDragStarted,
                  onDragEnd: controller.edgeDragEnded,
                ),
              ),
            ),
          if (flyout != null)
            Positioned(
              key: const ValueKey<String>('flyout'),
              left: metrics.chromeLeft,
              top: metrics.chromeTop,
              bottom: metrics.chromeInset,
              // The layout's panel width: the remembered width clamped to 240–440 while the panel is collapsed.
              width: layout.panelWidth,
              child: ZsPresence(
                open: flyoutShown,
                exit: motion.durExitLg,
                builder: (context, closing) => TapRegion(
                  groupId: widget.railGroup,
                  onTapOutside: (_) => controller.closeFlyout(),
                  child: BackdropGroup(
                    child: ShellPanelMotion(
                      key: ValueKey<String>(flyout.id),
                      closing: closing,
                      child: PinnedPanel(item: flyout, onClose: controller.unpin, identifier: 'flyout'),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rail item's panel: the panel island (strong glass, clipped) with the header — the icon at lg in
/// `--text-muted`, the title in `--type-panel-title`, the sm close button "Close", padding 14 12 12 16, gap 8 (DS
/// ui_kits/desktop/kit.css:84-86) — over the item's body in a scroll area, 10 above the bottom (kit.css:87).
///
/// VoiceOver reads it as a live region named after the item, so pinning announces it (DS
/// components/surfaces/Callout.prompt.md:11).
class PinnedPanel extends StatefulWidget {
  /// The panel of [item]; [onClose] unpins it.
  const PinnedPanel({required this.item, required this.onClose, this.identifier = 'panel', super.key});

  /// The item.
  final ShellRailItem item;

  /// Runs on the close button.
  final VoidCallback onClose;

  /// The prefix of the panel's identifiers: `<identifier>-close`, `<identifier>-body`.
  final String identifier;

  /// `padding:14px 12px 12px 16px` (DS ui_kits/desktop/kit.css:84).
  static const _header = EdgeInsets.fromLTRB(16, 14, 12, 12);

  /// `padding-bottom:10px` (DS ui_kits/desktop/kit.css:87).
  static const _body = EdgeInsets.only(bottom: 10);

  @override
  State<PinnedPanel> createState() => _PinnedPanelState();
}

class _PinnedPanelState extends State<PinnedPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ShellRailItem item = widget.item;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: item.label,
      child: ZsIsland(
        shape: ZsIslandShape.panel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: PinnedPanel._header,
              child: Row(
                spacing: metrics.space2,
                children: <Widget>[
                  ZanshinIcon(item.icon, size: ZsIconSize.lg, color: colors.textMuted),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZsType.panelTitle.copyWith(color: colors.text),
                    ),
                  ),
                  ZsIconButton(
                    icon: ZI.close,
                    label: context.l10n.panelClose,
                    size: ZsIconButtonSize.sm,
                    identifier: '${widget.identifier}-close',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ZsScrollArea(
                controller: _scroll,
                label: item.label,
                identifier: '${widget.identifier}-body',
                child: SingleChildScrollView(controller: _scroll, padding: PinnedPanel._body, child: item.panel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel's entrance and exit (DS ui_kits/desktop/kit.css:82-83; decision 16.40): in, a fade over `--dur-panel`
/// and a slide from −8 px × `--motion` on `--ease-glide`; out while [closing], a fade and a drift to −8 px ×
/// `--motion` over `--dur-exit-lg` on `--ease-exit`. The glass fades through [ZsFade]; under reduce motion only the
/// slide goes. It takes no pointer and no focus while it leaves. The inspector (Story 10.8) uses it with a [drift] of
/// +12 px from the right.
class ShellPanelMotion extends StatefulWidget {
  /// Animates [child] in, and out while [closing].
  const ShellPanelMotion({required this.closing, required this.child, this.drift = panelDrift, super.key});

  /// The panel's drift (DS ui_kits/desktop/kit.css:83, `translateX(calc(-8px * var(--motion)))`).
  static const double panelDrift = -8;

  /// The horizontal offset the island slides in from and drifts out to, before × `--motion`.
  final double drift;

  /// Whether the panel is leaving.
  final bool closing;

  /// The panel.
  final Widget child;

  @override
  State<ShellPanelMotion> createState() => _ShellPanelMotionState();
}

class _ShellPanelMotionState extends State<ShellPanelMotion> with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(ShellPanelMotion oldWidget) {
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
    final bool closing = widget.closing;
    // The exit runs the controller back from 1; flipping its curve keeps the value the remaining opacity.
    final Curve curve = closing ? motion.easeExit.flipped : motion.easeGlide;
    return IgnorePointer(
      ignoring: closing,
      child: ExcludeFocus(
        excluding: closing,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final double shown = curve.transform(_controller.value);
            return ZsFade(
              opacity: shown.clamp(0, 1),
              child: Transform.translate(
                offset: Offset(widget.drift * motion.motion * (1 - shown), 0),
                child: child,
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}
