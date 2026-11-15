// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// [path]'s parts as a file row shows them (Story 10.39): the file's `name`, the folder up to its last folder with its
/// `/` (`head`), and the last folder with its `/` (`tail`). A path without a folder has an empty head and tail.
({String name, String head, String tail}) inspectorPathParts(String path) {
  final int slash = path.lastIndexOf('/');
  if (slash < 0) {
    return (name: path, head: '', tail: '');
  }
  final String folder = path.substring(0, slash + 1);
  final int cut = folder.lastIndexOf('/', folder.length - 2);
  return (name: path.substring(slash + 1), head: folder.substring(0, cut + 1), tail: folder.substring(cut + 1));
}

/// A path drawn name first (Story 10.39; design inspector-study.css:116-122): the `name`, then [gap], then the folder
/// as its `head` and `tail`. Each gets its whole width while there is room; short of room the head gives way first,
/// then the tail, then the name — each ending in its own ellipsis, so the folder is cut in its middle. The three are
/// one-line texts, laid out with their max intrinsic widths: Flex has no shrink factors for this order. An optional
/// `note` (Story 10.42: "new", "deleted", "from …") follows the name inside its part and gives way with it.
class InspectorPathLabel extends MultiChildRenderObjectWidget {
  /// The label of `name`, `head` and `tail` in `nameStyle` and `folderStyle`, `note` after the name.
  InspectorPathLabel({
    required String name,
    required String head,
    required String tail,
    required TextStyle nameStyle,
    required TextStyle folderStyle,
    InlineSpan? note,
    this.gap = 8,
    super.key,
  }) : super(
         children: <Widget>[
           Text.rich(
             TextSpan(text: name, children: <InlineSpan>[?note]),
             style: nameStyle,
             maxLines: 1,
             softWrap: false,
             overflow: TextOverflow.ellipsis,
           ),
           _part(head, folderStyle),
           _part(tail, folderStyle),
         ],
       );

  /// The space between the name and a folder.
  final double gap;

  static Widget _part(String text, TextStyle style) =>
      Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style);

  @override
  RenderInspectorPathLabel createRenderObject(BuildContext context) => RenderInspectorPathLabel(gap: gap);

  @override
  void updateRenderObject(BuildContext context, RenderInspectorPathLabel renderObject) => renderObject.gap = gap;
}

/// The parent data of [RenderInspectorPathLabel]'s children.
class InspectorPathLabelParentData extends ContainerBoxParentData<RenderBox> {}

/// Lays out [InspectorPathLabel]: name, head, tail in a row, each at most its max intrinsic width, the room handed out
/// name first, then tail, then head.
class RenderInspectorPathLabel extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, InspectorPathLabelParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, InspectorPathLabelParentData> {
  /// A label with [gap] between the name and the folder.
  RenderInspectorPathLabel({required this._gap});

  double _gap;

  /// The space between the name and a folder.
  double get gap => _gap;
  set gap(double value) {
    if (value != _gap) {
      _gap = value;
      markNeedsLayout();
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! InspectorPathLabelParentData) {
      child.parentData = InspectorPathLabelParentData();
    }
  }

  List<RenderBox> get _parts => getChildrenAsList();

  /// The gap when a folder follows.
  double _gapFor(List<double> widths) => widths.length == 3 && widths[1] + widths[2] > 0 ? _gap : 0;

  List<double> _natural(double height) => <double>[
    for (final RenderBox part in _parts) part.getMaxIntrinsicWidth(height),
  ];

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final List<double> widths = _natural(height);
    return widths.fold<double>(0, (sum, w) => sum + w) + _gapFor(widths);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _parts.fold<double>(0, (high, part) => math.max(high, part.getMinIntrinsicHeight(width)));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _parts.fold<double>(0, (high, part) => math.max(high, part.getMaxIntrinsicHeight(width)));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  /// Each part's width in [maxWidth]: name, then tail, then head.
  List<double> _widths(double maxWidth) {
    final List<double> natural = _natural(double.infinity);
    if (natural.length != 3) {
      return natural;
    }
    final double gap = _gapFor(natural);
    final double room = maxWidth.isFinite ? maxWidth : double.infinity;
    final double name = math.min(natural[0], room);
    final double left = math.max(0, room - name - gap);
    final double tail = math.min(natural[2], left);
    final double head = math.min(natural[1], left - tail);
    return <double>[name, head, tail];
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final List<double> widths = _widths(constraints.maxWidth);
    final List<RenderBox> parts = _parts;
    var height = 0.0;
    for (var i = 0; i < parts.length; i++) {
      height = math.max(height, parts[i].getDryLayout(BoxConstraints.tightFor(width: widths[i])).height);
    }
    // The gap only before a folder that got room.
    final double width = widths.fold<double>(0, (sum, w) => sum + w) + _gapFor(widths);
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    final List<double> widths = _widths(constraints.maxWidth);
    final List<RenderBox> parts = _parts;
    var height = 0.0;
    for (var i = 0; i < parts.length; i++) {
      parts[i].layout(BoxConstraints.tightFor(width: widths[i]), parentUsesSize: true);
      height = math.max(height, parts[i].size.height);
    }
    var x = 0.0;
    for (var i = 0; i < parts.length; i++) {
      if (i == 1) {
        x += _gapFor(widths);
      }
      (parts[i].parentData! as InspectorPathLabelParentData).offset = Offset(x, (height - parts[i].size.height) / 2);
      x += widths[i];
    }
    size = constraints.constrain(Size(x, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
