// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'shell_controller.dart';

/// The rail (epics.md Story 11.3 item 4; DS ui_kits/desktop/chrome.jsx:140-157; kit.css:65-66): a rail island of
/// `ZsIconButton.lg` buttons, `--chrome-col` (52) wide, one per item — Bookmarks (10.14) and the Undo Timeline
/// (11.9); Workstreams is dropped (decision 16.26), and so is Reviews (decision 2026-10-31).
///
/// Each button is a Tab stop with its ring inside; it shows no tooltip — its hover preview takes that place — and
/// reports its pin as its toggled state; its identifier is `rail-<id>`. Hovering a button drives the controller's
/// hover intent; a click, ↩ or Space toggles the pin. VoiceOver reads the rail as the group "Panels".
class ShellRail extends StatelessWidget {
  /// The rail of [items].
  const ShellRail({required this.controller, required this.items, super.key});

  /// The shell's controller.
  final ShellController controller;

  /// The items, top to bottom.
  final List<ShellRailItem> items;

  /// The rail island's padding (DS components/surfaces/surfaces.css:5, `padding:5px`).
  static const double _padding = 5;

  /// The vertical centre of button [index] in the window: `--chrome-top`, the island's border and padding, the
  /// buttons and gaps above it, half a button.
  static double buttonCentre(ZsMetrics metrics, int index) =>
      metrics.chromeTop +
      ZsSurface.borderWidth +
      _padding +
      index * (metrics.chromeRailBtn + ZsIslandShape.rail.gap) +
      metrics.chromeRailBtn / 2;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: context.l10n.railLabel,
    child: ZsIsland(
      shape: ZsIslandShape.rail,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: ZsIslandShape.rail.gap,
        children: <Widget>[
          for (final ShellRailItem item in items)
            MouseRegion(
              onEnter: (_) => controller.railEnter(item.id),
              onExit: (_) => controller.railExit(),
              child: ZsIconButton(
                icon: item.icon,
                label: item.label,
                size: ZsIconButtonSize.lg,
                tooltip: false,
                active: controller.pinnedId == item.id,
                identifier: 'rail-${item.id}',
                onPressed: () => controller.activate(item.id),
              ),
            ),
        ],
      ),
    ),
  );
}
