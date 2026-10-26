// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeExtension;

import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_values.dart';

/// The commit graph's colour roles (Epic 10 house rule "Theme"), derived from [ZsColors] so no colour is typed twice.
///
/// Story 10.1 adds the canvas roles; Stories 10.2–10.4 add theirs. `ZsAppTheme.build` registers it once, so every
/// window and the catalogue get it; [of] falls back to [night].
@immutable
class GraphTheme extends ThemeExtension<GraphTheme> {
  /// Creates a graph theme; the app uses [night], [paper] and [GraphTheme.resolve].
  const GraphTheme({required this.canvas, required this.canvasBase});

  /// The graph roles of [colors].
  factory GraphTheme.fromColors(ZsColors colors) => GraphTheme(canvas: colors.canvas, canvasBase: colors.canvasBase);

  /// The graph roles [appearance] shows.
  factory GraphTheme.resolve(ZsAppearance appearance) => GraphTheme.fromColors(ZsColors.resolve(appearance));

  /// Night under Multicolor.
  static final night = GraphTheme.fromColors(ZsColors.night);

  /// Paper under Multicolor.
  static final paper = GraphTheme.fromColors(ZsColors.paper);

  /// The graph theme of the nearest [Theme], or [night] when it carries none.
  static GraphTheme of(BuildContext context) => Theme.of(context).extension<GraphTheme>() ?? night;

  /// The window-fixed `--canvas` behind the graph (DS tokens/colors.css:19, paper :59); 10.2 paints it.
  final ZsCanvasGradient canvas;

  /// `--canvas-base`, the canvas's flat fallback (DS tokens/colors.css:20, paper :60).
  final Color canvasBase;

  @override
  GraphTheme copyWith({ZsCanvasGradient? canvas, Color? canvasBase}) =>
      GraphTheme(canvas: canvas ?? this.canvas, canvasBase: canvasBase ?? this.canvasBase);

  @override
  GraphTheme lerp(GraphTheme? other, double t) {
    if (other == null) {
      return this;
    }
    return GraphTheme(
      canvas: ZsCanvasGradient.lerp(canvas, other.canvas, t),
      canvasBase: Color.lerp(canvasBase, other.canvasBase, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GraphTheme && other.canvas == canvas && other.canvasBase == canvasBase;

  @override
  int get hashCode => Object.hash(canvas, canvasBase);
}
