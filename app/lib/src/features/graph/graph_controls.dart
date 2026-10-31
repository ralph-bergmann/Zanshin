// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/calm_controller.dart';
import '../shell/shell_scope.dart';
import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_ports.dart';
import 'graph_preferences.dart';
import 'graph_search_controller.dart';
import 'graph_search_field.dart';
import 'graph_view_model.dart';

// The graph's controls in the floating top bar (Story 10.7; DS ui_kits/desktop/chrome.jsx:80-106, kit.css:59-62,
// :210-211): GraphCount, GraphViewControls (the VIEW island's content) and NewChangeButton (the ACTION slot's island).

/// The window width at or below which the count and its separator are not built (DS kit.css:210).
const double graphCountHideWidth = 1040;

/// The window width at or below which New change shows only its icon (DS kit.css:211).
const double newChangeIconOnlyWidth = 920;

/// The count (DS kit.css:59-60): "**N** of M" while the view shows fewer than `|all()|` changes, else "**M** changes"
/// ("**N** changes" while M is unknown); nothing without a layout. 12 px sans with tabular figures in `--text-dim`,
/// the number 600 in `--text-muted`; the tooltip "N of M changes shown" once M is known.
class GraphCount extends StatelessWidget {
  /// The count of [model]'s layout.
  const GraphCount({required this.model, super.key});

  /// The view model.
  final GraphViewModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final int? shown = model.shown;
      if (shown == null) {
        return const SizedBox.shrink();
      }
      // A revset naming hidden commits can show more than `all()` counts.
      final int? total = switch (model.total) {
        final int all => math.max(all, shown),
        null => null,
      };
      final ZsColors colors = ZsColors.of(context);
      final AppLocalizations strings = context.l10n;
      final TextStyle style = ZsType.body.copyWith(
        fontSize: ZsType.fsMd,
        height: 1,
        color: colors.textDim,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );
      final TextStyle bold = style.copyWith(
        fontWeight: ZsType.fwSemibold,
        fontVariations: const <FontVariation>[FontVariation.weight(600)],
        color: colors.textMuted,
      );
      final bool filtered = total != null && shown < total;
      final int number = filtered || total == null ? shown : total;
      // The message with a marker where the bold number goes, so the translation keeps its word order.
      const marker = '\u0000'; // l10n-ignore: a placeholder marker, never shown
      final String message = filtered
          ? strings.graphCountFiltered(marker, total)
          : strings.graphCountAll(number, marker);
      final List<String> parts = message.split(marker);
      final Widget text = Padding(
        // `.zk-n{padding:0 6px 0 2px}` (DS kit.css:59).
        padding: const EdgeInsets.fromLTRB(2, 0, 6, 0),
        child: Text.rich(
          TextSpan(
            style: style,
            children: <InlineSpan>[
              for (var i = 0; i < parts.length; i++) ...<InlineSpan>[
                if (i > 0) TextSpan(text: '$number', style: bold),
                TextSpan(text: parts[i]),
              ],
            ],
          ),
          maxLines: 1,
          softWrap: false,
        ),
      );
      return total == null ? text : ZsTooltip(message: strings.graphCountTooltip(shown, total), child: text);
    },
  );
}

/// The VIEW island's graph controls (Story 10.7): 10.21's [GraphSearchField] (when a search is given) and a separator,
/// the [GraphCount], a separator and the View options button with its popover. Room is left before the count for
/// 10.19's gap legend. At a window width of at most
/// [graphCountHideWidth] the count and its separator are not built.
///
/// **View options** (DS chrome.jsx:87-98; kit.css:62): a [ZsPopover] 340 wide, 14 below the button, its right edge 5
/// right of the button's, kept 8 inside the window: "Graph view" over Layout (Free | Compact), Detailed cards, Group
/// stacks and Card width (160–400 in 10s), all bound to [preferences], then "Appearance, diffs and more" ·
/// Settings…, which runs [onSettings] (disabled while null; 11.7 passes Settings on General). The button opens and
/// closes it; a press outside and Esc close it. Focus moves into it on open and back to the button on Esc; the Esc is
/// consumed and never reaches the graph. While open — its exit included — it holds the shell's calm scrolling.
class GraphViewControls extends StatelessWidget {
  /// The controls of [model] over [preferences].
  const GraphViewControls({
    required this.model,
    required this.preferences,
    this.search,
    this.onSettings,
    super.key,
  });

  /// The view model (the count).
  final GraphViewModel model;

  /// The graph search (Story 10.21), first in the island; none when null.
  final GraphSearchController? search;

  /// The View options.
  final GraphPreferences preferences;

  /// "Appearance, diffs and more"; null disables the row.
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width > graphCountHideWidth;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (search case final GraphSearchController search) ...<Widget>[
          GraphSearchField(search: search),
          const ZsIslandSeparator(),
        ],
        if (wide) ...<Widget>[GraphCount(model: model), const ZsIslandSeparator()],
        GraphViewOptionsButton(preferences: preferences, onSettings: onSettings),
      ],
    );
  }
}

/// The View options button and its popover (see [GraphViewControls]).
class GraphViewOptionsButton extends StatefulWidget {
  /// The button over [preferences].
  const GraphViewOptionsButton({required this.preferences, this.onSettings, super.key});

  /// The View options.
  final GraphPreferences preferences;

  /// "Appearance, diffs and more"; null disables the row.
  final VoidCallback? onSettings;

  /// The popover's gap below the button (`.zk-pop-r{top:calc(100% + 14px)}`, DS kit.css:62).
  static const double popoverGap = 14;

  /// How far the popover's right edge lies right of the button's (`.zk-pop-r{right:-5px}`, DS kit.css:62).
  static const double popoverOverhang = 5;

  @override
  State<GraphViewOptionsButton> createState() => _GraphViewOptionsButtonState();
}

class _GraphViewOptionsButtonState extends State<GraphViewOptionsButton> {
  final _menu = MenuController();
  final _button = FocusNode(debugLabel: 'View options');
  final _popover = FocusScopeNode(debugLabel: 'View options popover');
  var _open = false;
  var _closing = false;
  var _refocus = false;
  VoidCallback? _hide;
  CalmHold? _hold;

  @override
  void dispose() {
    _hold?.release();
    _button.dispose();
    _popover.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_menu.isOpen) {
      _close(refocus: true);
    } else {
      _menu.open();
    }
  }

  void _close({required bool refocus}) {
    if (_menu.isOpen) {
      _refocus = refocus;
      _menu.close();
    }
  }

  void _opened() {
    _hold?.release();
    _hold = ShellScope.maybeOf(context)?.openSurface();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing) {
        _popover.requestFocus();
      }
    });
  }

  void _closed() {
    _hold?.release();
    _hold = null;
    if (_refocus && _button.context != null) {
      _button.requestFocus();
    }
    _refocus = false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _close(refocus: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: _menu,
    consumeOutsideTaps: true,
    onOpenRequested: (position, show) {
      _hide = null;
      setState(() {
        _open = true;
        _closing = false;
      });
      show();
    },
    onCloseRequested: (hide) {
      if (_closing) {
        return;
      }
      _hide = hide;
      setState(() {
        _open = false;
        _closing = true;
      });
    },
    onOpen: _opened,
    onClose: _closed,
    overlayBuilder: (context, info) => Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _PopoverLayout(info.anchorRect),
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          onTapOutside: (_) => _close(refocus: false),
          child: FocusScope(
            node: _popover,
            onKeyEvent: _onKey,
            child: ListenableBuilder(
              listenable: widget.preferences,
              builder: (context, _) => _ViewOptionsPopover(
                preferences: widget.preferences,
                closing: _closing,
                onClosed: () {
                  final VoidCallback? hide = _hide;
                  _hide = null;
                  hide?.call();
                },
                onSettings: switch (widget.onSettings) {
                  final VoidCallback onSettings => () {
                    _close(refocus: false);
                    onSettings();
                  },
                  null => null,
                },
              ),
            ),
          ),
        ),
      ),
    ),
    builder: (context, controller, child) => ZsIconButton(
      icon: ZI.viewOptions,
      label: context.l10n.graphViewOptions,
      active: _open,
      focusNode: _button,
      onPressed: _toggle,
      identifier: 'graph-view-options',
    ),
  );
}

/// The popover's rows (DS chrome.jsx:88-97).
class _ViewOptionsPopover extends StatelessWidget {
  const _ViewOptionsPopover({
    required this.preferences,
    required this.closing,
    required this.onClosed,
    required this.onSettings,
  });

  final GraphPreferences preferences;
  final bool closing;
  final VoidCallback onClosed;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final GraphViewOptions options = preferences.options;
    // ZsPopover's default width is the design's 340.
    return ZsPopover(
      label: strings.graphViewOptions,
      closing: closing,
      onClosed: onClosed,
      identifier: 'graph-view-options-popover',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: <Widget>[
          ZsPopoverHeader(strings.graphViewTitle),
          ZsOptionRow(
            label: strings.graphLayout,
            child: ZsSegmented<GraphMode>(
              segments: <ZsSegment<GraphMode>>[
                ZsSegment<GraphMode>(
                  value: GraphMode.free,
                  label: strings.graphLayoutFree,
                  tooltip: strings.graphLayoutFreeTooltip,
                ),
                ZsSegment<GraphMode>(
                  value: GraphMode.compact,
                  label: strings.graphLayoutCompact,
                  tooltip: strings.graphLayoutCompactTooltip,
                ),
              ],
              value: options.layout,
              onChanged: preferences.setLayout,
              label: strings.graphLayout,
              identifier: 'graph-layout',
            ),
          ),
          ZsOptionRow(
            label: strings.graphDetailedCards,
            child: ZsSwitch(
              value: options.detailedCards,
              onChanged: preferences.setDetailedCards,
              label: strings.graphDetailedCards,
              identifier: 'graph-detailed-cards',
            ),
          ),
          ZsTooltip(
            message: strings.graphGroupStacksTooltip,
            child: ZsOptionRow(
              label: strings.graphGroupStacks,
              child: ZsSwitch(
                value: preferences.groupStacks,
                onChanged: preferences.setGroupStacks,
                label: strings.graphGroupStacks,
                identifier: 'graph-group-stacks',
              ),
            ),
          ),
          ZsOptionRow(
            label: strings.graphCardWidth,
            child: ZsSlider(
              value: options.cardWidth,
              onChanged: preferences.setCardWidth,
              min: GraphMetrics.minCardWidth,
              max: GraphMetrics.maxCardWidth,
              step: GraphPreferences.cardWidthStep,
              unit: strings.graphCardWidthUnit,
              label: strings.graphCardWidth,
              identifier: 'graph-card-width',
            ),
          ),
          const ZsPopoverSeparator(),
          ZsOptionLink(
            label: strings.graphMoreSettings,
            action: strings.settingsEllipsis,
            onPressed: onSettings,
            identifier: 'graph-more-settings',
          ),
        ],
      ),
    );
  }
}

/// Places the popover [GraphViewOptionsButton.popoverGap] below the button, its right edge
/// [GraphViewOptionsButton.popoverOverhang] right of the button's, kept 8 inside the window.
class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.anchor);

  final Rect anchor;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(math.max(0, constraints.maxWidth - 2 * _margin), math.max(0, constraints.maxHeight - 2 * _margin)),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double x = anchor.right + GraphViewOptionsButton.popoverOverhang - childSize.width;
    final double y = anchor.bottom + GraphViewOptionsButton.popoverGap;
    return Offset(
      math.max(_margin, math.min(x, size.width - _margin - childSize.width)),
      math.max(_margin, math.min(y, size.height - _margin - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) => oldDelegate.anchor != anchor;
}

/// New change, the top bar's one primary action (Story 10.7; DS chrome.jsx:105, kit.css:211): `jj new` on @ through
/// [GraphViewModel.run] (the model moves a selected @ to the born change and reveals it). Disabled while an action
/// runs or the working copy is stale, without [GraphActions], or without @ in the layout. At a window width of at most
/// [newChangeIconOnlyWidth] it shows only its icon.
class NewChangeButton extends StatelessWidget {
  /// New change for [model].
  const NewChangeButton({required this.model, super.key});

  /// The view model.
  final GraphViewModel model;

  @override
  Widget build(BuildContext context) {
    final bool iconOnly = MediaQuery.sizeOf(context).width <= newChangeIconOnlyWidth;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final GraphLayout? layout = model.layout;
        final int? at = layout?.workingCopyIndex;
        final String? parent = at == null ? null : layout!.keyOf(at);
        final bool enabled = parent != null && model.hasActions && model.actionsEnabled;
        return ZsTooltip(
          message: context.l10n.newChangeTooltip,
          child: ZsButton(
            label: context.l10n.newChange,
            variant: ZsButtonVariant.primary,
            size: ZsButtonSize.lg,
            icon: ZI.plus,
            iconOnly: iconOnly,
            onPressed: enabled ? () => unawaited(model.run(GraphNew(parents: <String>[parent]))) : null,
            identifier: 'graph-new-change',
          ),
        );
      },
    );
  }
}
