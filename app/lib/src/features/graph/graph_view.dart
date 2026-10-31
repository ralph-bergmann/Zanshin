// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../shell/graph_insets.dart';
import '../shell/shell_scope.dart';
import 'graph_canvas.dart';
import 'graph_card.dart';
import 'graph_layout.dart';
import 'graph_view_model.dart';
import 'stale_notice.dart';

/// The commit graph bound to its [GraphViewModel] (Story 10.5): the model's layout and reveal on a [GraphCanvas], the
/// selection kept in step with the cards, the model's "now" copied into the cards (refreshed when the window turns
/// active), and the shell's [GraphInsets] as the viewport's insets — so the visible rect the reveals centre in is the
/// rect the chrome leaves free — or [insets] outside a shell. Pans and flings go to the shell's calm scrolling.
///
/// The empty state and a failed load show a caption centred in the visible rect, the failure with a quiet Retry
/// (Claude's proposal for design question (d)); loading shows nothing, and the stale state is [staleNotice]'s.
class GraphView extends StatefulWidget {
  /// The graph of [model].
  const GraphView({
    required this.model,
    this.options = const GraphViewOptions(),
    this.insets = EdgeInsets.zero,
    super.key,
  });

  /// The view model; its owner initialises and disposes it.
  final GraphViewModel model;

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

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  late final _cards = GraphCardController(now: widget.model.now.value);
  bool? _inactive;

  @override
  void initState() {
    super.initState();
    _attach(widget.model);
    _cards.selected.addListener(_selectionChanged);
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
    _inactive = inactive;
  }

  @override
  void dispose() {
    _detach(widget.model);
    _cards.dispose();
    super.dispose();
  }

  void _attach(GraphViewModel model) {
    model
      ..addListener(_modelChanged)
      ..now.addListener(_nowChanged);
    _cards
      ..selected.value = model.selected
      ..now.value = model.now.value;
  }

  void _detach(GraphViewModel model) {
    model
      ..removeListener(_modelChanged)
      ..now.removeListener(_nowChanged);
  }

  void _modelChanged() {
    _cards.selected.value = widget.model.selected;
    setState(() {});
  }

  void _nowChanged() => _cards.now.value = widget.model.now.value;

  void _selectionChanged() => widget.model.select(_cards.selected.value);

  void _reportUserScroll(double amount) => ShellScope.maybeOf(context)?.reportUserScroll(amount);

  EdgeInsets _insets(BuildContext context) {
    final GraphInsets? shell = context.dependOnInheritedWidgetOfExactType<ShellScope>()?.layout.insets;
    return shell == null ? widget.insets : EdgeInsets.fromLTRB(shell.left, shell.top, shell.right, shell.bottom);
  }

  @override
  Widget build(BuildContext context) {
    final GraphViewModel model = widget.model;
    final EdgeInsets insets = _insets(context);
    final GraphLayout? layout = model.layout;
    final Widget? caption = _caption(context, model);
    return Stack(
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
            onUserScroll: _reportUserScroll,
          ),
        if (caption != null)
          Padding(
            key: const ValueKey<String>('graph-caption'),
            padding: insets,
            child: Center(child: caption),
          ),
      ],
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
              'The graph could not be loaded (${error.code}).',
              style: ZsType.control.copyWith(color: colors.text),
            ),
            const SizedBox(width: 13),
            ZsButton(label: 'Retry', onPressed: model.retry, identifier: 'graph.retry'),
          ],
        ),
      );
    }
    if (model.empty && model.revsetError == null) {
      return Text('No changes match this revset.', style: ZsType.control.copyWith(color: colors.textMuted));
    }
    return null;
  }
}
