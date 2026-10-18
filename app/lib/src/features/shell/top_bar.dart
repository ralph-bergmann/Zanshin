// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The top bar's three groups (DS readme.md:84).
enum TopBarGroup {
  /// Left: the project capsule (11.5).
  place,

  /// Centre: the View island — search (10.21) and the view controls (10.7).
  view,

  /// Right: the sync group (11.8), then New change (10.7).
  action,
}

/// The top bar Place · View · Action (epics.md Story 11.3 item 3; DS ui_kits/desktop/kit.css:32-33, :62; readme.md:84).
///
/// The caller places it at `--chrome-first-x` … `--chrome-inset` from the right, at `--chrome-bar-y`, `--chrome-h`
/// high. Its grid is CSS `minmax(max-content,1fr) minmax(0,max-content) minmax(max-content,1fr)` with 12 px gaps,
/// laid out by one render box ([_TopBarGrid]): when the window narrows the centre gives way first and the side
/// groups keep their size. PLACE starts its column, the VIEW island is centred in its column, ACTION ends its
/// column; its two islands sit 8 apart (DS kit.css:62, `--space-2`).
///
/// Every slot left null shows an empty 44 × 44 island (Claude's proposal, until its story lands). The VIEW island is
/// built here around [view], a labelled group; focus inside it shows through [viewFocus]. [decorate] wraps each
/// group (the shell's calm-scrolling motion).
class ShellTopBar extends StatelessWidget {
  /// The bar over the slots.
  const ShellTopBar({
    required this.decorate,
    this.projectCapsule,
    this.view,
    this.syncGroup,
    this.newChange,
    this.viewFocus,
    super.key,
  });

  /// The project capsule island (11.5).
  final Widget? projectCapsule;

  /// The View island's content (10.21, 10.7).
  final Widget? view;

  /// The sync group island (11.8).
  final Widget? syncGroup;

  /// The New change island (10.7).
  final Widget? newChange;

  /// Has focus while focus is inside the View island.
  final FocusNode? viewFocus;

  /// Wraps each group's widget.
  final Widget Function(TopBarGroup group, Widget child) decorate;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final Widget? content = view;
    Widget viewIsland = content == null
        ? const ShellEmptyIsland()
        : Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'View',
            child: ZsIsland(child: content),
          );
    final FocusNode? focus = viewFocus;
    if (focus != null) {
      viewIsland = Focus(
        focusNode: focus,
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        child: viewIsland,
      );
    }
    return _TopBarGrid(
      gap: metrics.chromeInset,
      height: metrics.chromeH,
      place: decorate(TopBarGroup.place, projectCapsule ?? const ShellEmptyIsland()),
      view: decorate(TopBarGroup.view, viewIsland),
      action: decorate(
        TopBarGroup.action,
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: metrics.space2,
          children: <Widget>[syncGroup ?? const ShellEmptyIsland(), newChange ?? const ShellEmptyIsland()],
        ),
      ),
    );
  }
}

/// The island an empty slot shows until its story lands: 44 × 44 (`--chrome-h`) bar glass with nothing on it
/// (Claude's proposal); VoiceOver skips it.
class ShellEmptyIsland extends StatelessWidget {
  /// An empty island.
  const ShellEmptyIsland({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: ZsMetrics.of(context).chromeH,
      child: const ZsIsland(child: SizedBox.shrink()),
    ),
  );
}

enum _BarSlot { place, view, action }

/// The bar's grid as one render box (see [ShellTopBar]): with the groups' max-content widths L, C and R and the box
/// width A, `free = A − 2·gap − L − R`, the centre column `col2 = clamp(free, 0, C)`, `S = A − 2·gap − col2`, and the
/// side columns share S as CSS grid resolves the two `minmax(max-content,1fr)` tracks: `col1 = max(L, S/2)` unless
/// R > S/2, then `col1 = S − R`; `col3 = S − col1`. Sides wider than the bar overflow to the right.
class _TopBarGrid extends SlottedMultiChildRenderObjectWidget<_BarSlot, RenderBox> {
  /// The grid over [place], [view] and [action].
  const _TopBarGrid({
    required this.place,
    required this.view,
    required this.action,
    required this.gap,
    required this.height,
  });

  /// The left group.
  final Widget place;

  /// The centre group, laid out at most as wide as its column.
  final Widget view;

  /// The right group.
  final Widget action;

  /// The gap between the columns.
  final double gap;

  /// The bar's height; each group is centred in it.
  final double height;

  @override
  Iterable<_BarSlot> get slots => _BarSlot.values;

  @override
  Widget childForSlot(_BarSlot slot) => switch (slot) {
    _BarSlot.place => place,
    _BarSlot.view => view,
    _BarSlot.action => action,
  };

  @override
  _RenderTopBarGrid createRenderObject(BuildContext context) => _RenderTopBarGrid(gap: gap, height: height);

  @override
  void updateRenderObject(BuildContext context, _RenderTopBarGrid renderObject) {
    renderObject
      ..gap = gap
      ..height = height;
  }
}

/// The render box of [_TopBarGrid].
class _RenderTopBarGrid extends RenderBox with SlottedContainerRenderObjectMixin<_BarSlot, RenderBox> {
  /// A grid with [gap] between its columns, [height] high.
  _RenderTopBarGrid({required this._gap, required this._height});

  /// The gap between the columns.
  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (value != _gap) {
      _gap = value;
      markNeedsLayout();
    }
  }

  /// The bar's height.
  double get height => _height;
  double _height;
  set height(double value) {
    if (value != _height) {
      _height = value;
      markNeedsLayout();
    }
  }

  RenderBox? get _place => childForSlot(_BarSlot.place);
  RenderBox? get _view => childForSlot(_BarSlot.view);
  RenderBox? get _action => childForSlot(_BarSlot.action);

  /// The column widths for a box [width] wide (see [_TopBarGrid]).
  ({double col1, double col2, double col3}) _columns(double width, double l, double c, double r) {
    final double free = width - 2 * _gap - l - r;
    if (free < 0) {
      return (col1: l, col2: 0, col3: r);
    }
    final double col2 = math.min(free, c);
    final double s = width - 2 * _gap - col2;
    final double col1 = r > s / 2 ? s - r : math.max(l, s / 2);
    return (col1: col1, col2: col2, col3: s - col1);
  }

  static double _maxContent(RenderBox? child, double height) => child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(Size(constraints.maxWidth, _height));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    final double l = _maxContent(_place, _height);
    final double c = _maxContent(_view, _height);
    final double r = _maxContent(_action, _height);
    final (:double col1, :double col2, :double col3) = _columns(size.width, l, c, r);
    Size lay(RenderBox? child, double maxWidth) {
      if (child == null) {
        return Size.zero;
      }
      child.layout(BoxConstraints(maxWidth: maxWidth, maxHeight: _height), parentUsesSize: true);
      return child.size;
    }

    void place(RenderBox? child, double x, Size childSize) {
      if (child != null) {
        (child.parentData! as BoxParentData).offset = Offset(x, (_height - childSize.height) / 2);
      }
    }

    final Size placeSize = lay(_place, l);
    final Size viewSize = lay(_view, col2);
    final Size actionSize = lay(_action, r);
    place(_place, 0, placeSize);
    place(_view, col1 + _gap + (col2 - viewSize.width) / 2, viewSize);
    place(_action, col1 + _gap + col2 + _gap + col3 - actionSize.width, actionSize);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height;

  @override
  double computeMaxIntrinsicHeight(double width) => _height;

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final RenderBox child in children) {
      context.paintChild(child, offset + (child.parentData! as BoxParentData).offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final RenderBox child in children.toList().reversed) {
      final Offset offset = (child.parentData! as BoxParentData).offset;
      final bool hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) {
        return true;
      }
    }
    return false;
  }
}
