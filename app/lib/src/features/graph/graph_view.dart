// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show Bookmark;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/calm_controller.dart';
import '../shell/graph_insets.dart';
import '../shell/shell_scope.dart';
import 'at_pill.dart';
import 'graph_canvas.dart';
import 'graph_card.dart';
import 'graph_card_menu.dart';
import 'graph_inspector.dart';
import 'graph_layout.dart';
import 'graph_search_controller.dart';
import 'graph_view_model.dart';
import 'stale_notice.dart';

/// The commit graph bound to its [GraphViewModel] (Story 10.5): the model's layout and reveal on a [GraphCanvas], the
/// selection kept in step with the cards, the model's "now" copied into the cards (refreshed when the window turns
/// active), and the shell's [GraphInsets] as the viewport's insets — so the visible rect the reveals centre in is the
/// rect the chrome leaves free — or [insets] outside a shell. Pans and flings go to the shell's calm scrolling.
///
/// The empty state and a failed load show a caption centred in the visible rect, the failure with a quiet Retry
/// (Claude's proposal for design question (d)); loading shows nothing, and the stale state is [staleNotice]'s.
///
/// Story 10.6: the graph is one Tab stop; while it has focus the selection (else @) carries the keyboard ring, Enter
/// or Space selects it, and Esc closes an open card menu, then clears the selection (no window-level listener). A
/// double-click runs [GraphViewModel.edit]. Hover is off during calm scrolling and in an inactive window. The @ pill
/// is [atPill]'s.
///
/// Story 10.9: the card affordances follow [GraphViewModel.actionsEnabled]; the running action's cards paint at
/// `--disabled-opacity` (Claude's proposal for 10.3 design question (e)) and its reload is anchored on
/// [GraphViewModel.anchorHint].
///
/// Story 10.15: the card menu and the bookmark popover ([GraphCardMenuHost], [GraphBookmarkMenuHost]) float over the
/// graph; a scroll over it, a window resize and the window turning inactive close them.
class GraphView extends StatefulWidget {
  /// The graph of [model].
  const GraphView({
    required this.model,
    this.options = const GraphViewOptions(),
    this.insets = EdgeInsets.zero,
    this.inspectorModel,
    this.bookmarks,
    this.search,
    super.key,
  });

  /// The graph search a gap's "Show in `all()`" switches (Story 10.19); without one the model switches alone.
  final GraphSearchController? search;

  /// The view model; its owner initialises and disposes it.
  final GraphViewModel model;

  /// The inspector the card menu's Describe… opens (Story 10.15); not `inspector`, the shell slot's name.
  final InspectorViewModel? inspectorModel;

  /// `jj bookmark list --all-remotes`, read by the bookmark popover for Track / Untrack (Story 10.15).
  final Future<List<Bookmark>> Function()? bookmarks;

  /// The card width and detail.
  final GraphViewOptions options;

  /// The insets outside a shell.
  final EdgeInsets insets;

  /// The shell's stale-notice slot for [model]: the notice while the working copy is stale, else null (the shell
  /// fades it out). The host rebuilds it when [model] notifies.
  static Widget? staleNotice(GraphViewModel model) {
    final GraphStale? stale = model.stale;
    if (stale == null) {
      return null;
    }
    return StaleNotice(
      command: stale.command,
      message: stale.message,
      busy: model.staleUpdating,
      onUpdate: () => unawaited(model.updateStale()),
    );
  }

  /// The shell's `atPill` slot for [model] (Story 10.6 item 6): the @ pill while @ lies outside the unobscured area,
  /// fading out when it shows again.
  static Widget atPill(GraphViewModel model) => GraphAtPill(model: model);

  /// The shell's `inspector` slot for [inspector] (Story 10.8): the inspector while its graph has a selection, else
  /// null (the shell plays its exit). The host rebuilds it when the graph's model notifies.
  static Widget? inspector(InspectorViewModel inspector) =>
      inspector.graph.selected == null ? null : GraphInspector(model: inspector);

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  late final _cards = GraphCardController(now: widget.model.now.value)..onEdit = _edit;
  final _focus = FocusNode(debugLabel: 'graph');

  /// The focus came from a press: no focus card (no ring, no reveal) until Enter or Space, or focus leaves.
  var _pointerFocus = false;
  bool? _inactive;
  Size? _windowSize;
  ValueListenable<CalmPhase>? _calm;

  @override
  void initState() {
    super.initState();
    _attach(widget.model);
    _cards.selected.addListener(_selectionChanged);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      _detach(oldWidget.model);
      _attach(widget.model);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool inactive = ZsAppearance.of(context).inactive;
    if (_inactive == true && !inactive) {
      // After this build: the new "now" rebuilds the canvas's day axis; the reload's snapshot takes in what other
      // apps changed in the working copy meanwhile.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.model
            ..refreshNow()
            ..reload();
        }
      });
    }
    final Size? size = MediaQuery.maybeSizeOf(context);
    // A window that turns inactive or changes size closes an open card menu or bookmark popover (Story 10.15); after
    // this build, since the menus close through setState.
    if ((inactive && _inactive == false) || (_windowSize != null && size != _windowSize)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _cards.closeMenus();
        }
      });
    }
    _windowSize = size;
    _inactive = inactive;
    final ValueListenable<CalmPhase>? calm = ShellScope.maybeOf(context)?.calm;
    if (!identical(calm, _calm)) {
      _calm?.removeListener(_hoverGate);
      _calm = calm?..addListener(_hoverGate);
    }
    _hoverGate();
  }

  // Debug only (hot reload): a changed layout or router shows without a jj operation.
  @override
  void reassemble() {
    super.reassemble();
    widget.model.reload();
  }

  @override
  void dispose() {
    _calm?.removeListener(_hoverGate);
    _detach(widget.model);
    _focus.dispose();
    _cards.dispose();
    super.dispose();
  }

  /// No hover while calm scrolling runs or the window is not key; turning it off clears the hover.
  void _hoverGate() => _cards.hoverEnabled = !(_inactive ?? false) && !(_calm?.value.calm ?? false);

  void _edit(String key) => unawaited(widget.model.edit(key));

  void _showGap(GraphGapTarget gap) => unawaited(widget.search?.showGap(gap) ?? widget.model.showGap(gap).then((_) {}));

  /// While the graph has focus, the focus card is the selection, else @ (the roving focus rests there, design
  /// question (c)).
  void _focusChanged() {
    if (!_focus.hasFocus) {
      _pointerFocus = false;
    }
    // macOS's highlight mode stays traditional under a mouse, so a press must hide the focus card itself.
    if (!_focus.hasFocus || _pointerFocus) {
      _cards.focused.value = null;
      return;
    }
    final GraphLayout? layout = widget.model.layout;
    final int? at = layout?.workingCopyIndex;
    final String? current = _cards.focused.value;
    // A folded focus key moves to its stack card (Story 10.17), which is shown and expands on Enter.
    final int? place = current == null ? null : layout?.placeOfKey(current);
    // A cleared selection keeps the focus card where it is, so Esc scrolls nothing.
    _cards.focused.value =
        _cards.selected.value ??
        (place != null ? layout!.keyOf(place) : null) ??
        (at == null ? null : layout!.keyOf(at));
  }

  /// Esc closes an open card menu, then clears the selection (the 2026-10-14 order); Enter or Space selects the focus
  /// card; ← collapses the focused member's expanded run, → expands a focused stack card. Only while the graph has
  /// focus.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      // A click still in its double-click window must not select after Esc.
      _cards.cancelClick();
      if (_cards.menuOpen.value != null) {
        _cards.menuOpen.value = null;
        return KeyEventResult.handled;
      }
      if (_cards.selected.value != null) {
        _cards.selected.value = null;
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space) {
      if (_pointerFocus) {
        _pointerFocus = false;
        _focusChanged();
      }
      final String? focused = _cards.focused.value;
      final GraphLayout? layout = widget.model.layout;
      final int? node = focused == null ? null : layout?.indexOfKey(focused);
      if (node != null && layout!.isStackNode(node)) {
        // A stack card expands; it is never selected (Story 10.17).
        _cards.onExpandStack?.call(focused!);
        return KeyEventResult.handled;
      }
      if (focused != null) {
        _cards.select(focused);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      // The macOS outline convention: ← collapses a focused member's expanded run, → expands a focused stack card.
      if (_pointerFocus) {
        _pointerFocus = false;
        _focusChanged();
      }
      final String? focused = _cards.focused.value;
      final GraphLayout? layout = widget.model.layout;
      final int? node = focused == null ? null : layout?.indexOfKey(focused);
      final int? run = node == null ? null : layout!.runOf(node);
      if (run == null) {
        return KeyEventResult.ignored;
      }
      final collapsed = layout!.stackNodeOf(run) != null;
      if (key == LogicalKeyboardKey.arrowLeft && !collapsed) {
        _cards.onCollapseStack?.call(focused!);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight && layout.isStackNode(node!)) {
        _cards.onExpandStack?.call(focused!);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _attach(GraphViewModel model) {
    model
      ..addListener(_modelChanged)
      ..now.addListener(_nowChanged);
    _cards
      ..selected.value = model.selected
      ..now.value = model.now.value
      ..actionsEnabled.value = model.actionsEnabled;
  }

  void _detach(GraphViewModel model) {
    model
      ..removeListener(_modelChanged)
      ..now.removeListener(_nowChanged);
  }

  void _modelChanged() {
    _cards
      ..selected.value = widget.model.selected
      ..actionsEnabled.value = widget.model.actionsEnabled;
    _focusChanged();
    setState(() {});
  }

  void _nowChanged() => _cards.now.value = widget.model.now.value;

  void _selectionChanged() {
    widget.model.select(_cards.selected.value);
    _focusChanged();
  }

  void _reportUserScroll(double amount) => ShellScope.maybeOf(context)?.reportUserScroll(amount);

  @override
  Widget build(BuildContext context) {
    final GraphViewModel model = widget.model;
    final GraphInsets? shell = context.dependOnInheritedWidgetOfExactType<ShellScope>()?.layout.insets;
    final EdgeInsets insets = shell == null
        ? widget.insets
        : EdgeInsets.fromLTRB(shell.left, shell.top, shell.right, shell.bottom);
    final GraphLayout? layout = model.layout;
    final Widget? caption = _caption(context, model);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Listener(
        // A press in the graph gives it focus (Esc acts then), without showing the keyboard ring.
        onPointerDown: (_) {
          _pointerFocus = true;
          _focus.hasFocus ? _focusChanged() : _focus.requestFocus();
        },
        // A wheel or trackpad scroll over the graph closes an open card menu or bookmark popover (Story 10.15).
        onPointerSignal: (_) => _cards.closeMenus(),
        onPointerPanZoomStart: (_) => _cards.closeMenus(),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (layout != null)
              GraphCanvas(
                key: const ValueKey<String>('graph-canvas'),
                layout: layout,
                cards: _cards,
                options: widget.options,
                insets: insets,
                reveal: model.reveal,
                pulse: model.pulse,
                pendingKeys: model.pendingKeys,
                anchorHint: model.anchorHint,
                content: model.content,
                onUserScroll: _reportUserScroll,
                onWorkingCopyDirection: model.setWorkingCopyDirection,
                inspectorOpen: (shell?.inspectorWidth ?? 0) > 0,
                entering: model.entering,
                onExpandStack: model.expandStack,
                onCollapseStack: model.collapseStack,
                flash: model.flash,
                onShowGap: _showGap,
                showChange: model.showChange,
              ),
            if (layout != null) ...<Widget>[
              GraphCardMenuHost(cards: _cards, model: model, inspector: widget.inspectorModel),
              GraphBookmarkMenuHost(cards: _cards, model: model, bookmarks: widget.bookmarks),
            ],
            if (caption != null)
              Padding(
                key: const ValueKey<String>('graph-caption'),
                padding: insets,
                child: Center(child: caption),
              ),
          ],
        ),
      ),
    );
  }

  Widget? _caption(BuildContext context, GraphViewModel model) {
    final ZsColors colors = ZsColors.of(context);
    if (model.error case final error?) {
      return ZsGlass(
        radius: ZsMetrics.of(context).radiusIsland,
        padding: const EdgeInsets.fromLTRB(16, 7, 7, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              context.l10n.graphLoadFailed(error.code),
              style: ZsType.control.copyWith(color: colors.text),
            ),
            const SizedBox(width: 13),
            ZsButton(label: context.l10n.graphRetry, onPressed: model.retry, identifier: 'graph.retry'),
          ],
        ),
      );
    }
    if (model.empty && model.revsetError == null) {
      return Text(context.l10n.graphEmpty, style: ZsType.control.copyWith(color: colors.textMuted));
    }
    return null;
  }
}
