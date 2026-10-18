// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// Fades every material below it — the one way to fade glass (Story 11.3; deferred-work, Story 11.2 item I1).
///
/// An `Opacity` or a `FadeTransition` above a `BackdropFilter` makes the engine paint the filter into an empty
/// offscreen layer, so the blur is gone for the whole fade. `ZsFade` paints nothing itself: each `ZsSurface` below
/// reads [ZsFade.of] and fades its own parts — the box through an `Opacity` inside the filter, the blur through the
/// filter's alpha, the drop shadows by their colour — which together look like CSS `opacity` on the whole surface.
///
/// Content that is not a material (a label beside an island) fades with an `Opacity` of its own; nested fades
/// multiply.
class ZsFade extends InheritedWidget {
  /// Fades the materials in [child] to [opacity] (0 hidden, 1 as painted).
  const ZsFade({required this.opacity, required super.child, super.key})
    : assert(opacity >= 0 && opacity <= 1, 'An opacity lies between 0 and 1.');

  /// This fade's own opacity.
  final double opacity;

  /// The product of every enclosing [ZsFade]'s opacity, 1 without one; [context] depends on each of them.
  static double of(BuildContext context) {
    var product = 1.0;
    InheritedElement? element = context.getElementForInheritedWidgetOfExactType<ZsFade>();
    while (element != null) {
      context.dependOnInheritedElement(element);
      product *= (element.widget as ZsFade).opacity;
      Element? parent;
      element.visitAncestorElements((ancestor) {
        parent = ancestor;
        return false;
      });
      element = parent?.getElementForInheritedWidgetOfExactType<ZsFade>();
    }
    return product;
  }

  @override
  bool updateShouldNotify(ZsFade oldWidget) => opacity != oldWidget.opacity;
}
