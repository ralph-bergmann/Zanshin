// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeExtension;

import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_values.dart';

/// The commit graph's colour roles (Epic 10 house rule "Theme"), derived from [ZsColors] so no colour is typed twice.
///
/// Story 10.1 adds the canvas roles, 10.2 the day axis's; Stories 10.3–10.4 add theirs. `ZsAppTheme.build` registers
/// it once, so every window and the catalogue get it; [of] falls back to [night].
@immutable
class GraphTheme extends ThemeExtension<GraphTheme> {
  /// Creates a graph theme; the app uses [night], [paper] and [GraphTheme.resolve].
  const GraphTheme({
    required this.canvas,
    required this.canvasBase,
    required this.dayGuide,
    required this.dayLabelText,
    required this.dayLabelFill,
    required this.dayLabelBorder,
  });

  /// The graph roles of [colors].
  factory GraphTheme.fromColors(ZsColors colors) => GraphTheme(
    canvas: colors.canvas,
    canvasBase: colors.canvasBase,
    dayGuide: colors.borderStrong,
    dayLabelText: colors.textMuted,
    dayLabelFill: colors.cardSolid,
    dayLabelBorder: colors.border,
  );

  /// The graph roles [appearance] shows.
  factory GraphTheme.resolve(ZsAppearance appearance) => GraphTheme.fromColors(ZsColors.resolve(appearance));

  /// Night under Multicolor.
  static final night = GraphTheme.fromColors(ZsColors.night);

  /// Paper under Multicolor.
  static final paper = GraphTheme.fromColors(ZsColors.paper);

  /// The graph theme of the nearest [Theme], or [night] when it carries none.
  static GraphTheme of(BuildContext context) => Theme.of(context).extension<GraphTheme>() ?? night;

  /// The window-fixed `--canvas` behind the graph (DS tokens/colors.css:19, paper :59), painted by `ZsCanvas`.
  final ZsCanvasGradient canvas;

  /// `--canvas-base`, the canvas's flat fallback (DS tokens/colors.css:20, paper :60).
  final Color canvasBase;

  /// The day divider's dashed stroke, `--border-strong` (DS components/graph/graph.css:101 `.zs-day-guide`).
  final Color dayGuide;

  /// The day label's text, `--text-muted` (graph.css:103 `.zs-day-label`).
  final Color dayLabelText;

  /// The day label's fill, `--card-solid` (graph.css:103).
  final Color dayLabelFill;

  /// The day label's 1 px border, `--border` (graph.css:103).
  final Color dayLabelBorder;

  @override
  GraphTheme copyWith({
    ZsCanvasGradient? canvas,
    Color? canvasBase,
    Color? dayGuide,
    Color? dayLabelText,
    Color? dayLabelFill,
    Color? dayLabelBorder,
  }) => GraphTheme(
    canvas: canvas ?? this.canvas,
    canvasBase: canvasBase ?? this.canvasBase,
    dayGuide: dayGuide ?? this.dayGuide,
    dayLabelText: dayLabelText ?? this.dayLabelText,
    dayLabelFill: dayLabelFill ?? this.dayLabelFill,
    dayLabelBorder: dayLabelBorder ?? this.dayLabelBorder,
  );

  @override
  GraphTheme lerp(GraphTheme? other, double t) {
    if (other == null) {
      return this;
    }
    return GraphTheme(
      canvas: ZsCanvasGradient.lerp(canvas, other.canvas, t),
      canvasBase: Color.lerp(canvasBase, other.canvasBase, t)!,
      dayGuide: Color.lerp(dayGuide, other.dayGuide, t)!,
      dayLabelText: Color.lerp(dayLabelText, other.dayLabelText, t)!,
      dayLabelFill: Color.lerp(dayLabelFill, other.dayLabelFill, t)!,
      dayLabelBorder: Color.lerp(dayLabelBorder, other.dayLabelBorder, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphTheme &&
          other.canvas == canvas &&
          other.canvasBase == canvasBase &&
          other.dayGuide == dayGuide &&
          other.dayLabelText == dayLabelText &&
          other.dayLabelFill == dayLabelFill &&
          other.dayLabelBorder == dayLabelBorder;

  @override
  int get hashCode => Object.hash(canvas, canvasBase, dayGuide, dayLabelText, dayLabelFill, dayLabelBorder);
}
