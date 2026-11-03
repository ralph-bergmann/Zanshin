// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeExtension;

import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_values.dart';

/// The commit graph's colour roles (Epic 10 house rule "Theme"), derived from [ZsColors] so no colour is typed twice.
///
/// Story 10.1 adds the canvas roles, 10.2 the day axis's, 10.3 the card's; Story 10.4 adds its own. `ZsAppTheme.build`
/// registers it once, so every window and the catalogue get it; [of] falls back to [night].
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
    required this.cardFill,
    required this.cardFillHover,
    required this.cardBorder,
    required this.cardBorderHover,
    required this.cardSelectedBorder,
    required this.workingCopyLine,
    required this.workingCopyTint,
    required this.atBadgeFill,
    required this.atBadgeText,
    required this.cardText,
    required this.cardTextMuted,
    required this.cardTextDim,
    required this.cardTextFaint,
    required this.conflict,
    required this.hatch,
    required this.hatchMark,
    required this.focusRing,
    required this.dropTargetLine,
    required this.edge,
    required this.edgeHover,
    required this.lineage,
    required this.lineageGlow,
    required this.gapCut,
    required this.gapCutHover,
    required this.gapText,
    required this.gapTextHover,
    this.gapClearance = 12,
  });

  /// The graph roles of [colors].
  factory GraphTheme.fromColors(ZsColors colors) => GraphTheme(
    canvas: colors.canvas,
    canvasBase: colors.canvasBase,
    dayGuide: colors.borderStrong,
    dayLabelText: colors.textMuted,
    dayLabelFill: colors.cardSolid,
    dayLabelBorder: colors.border,
    cardFill: colors.cardSolid,
    cardFillHover: colors.cardSolidHi,
    cardBorder: colors.borderStrong,
    cardBorderHover: colors.edgeHov,
    cardSelectedBorder: colors.accentLine,
    workingCopyLine: colors.co,
    workingCopyTint: colors.coSoft,
    atBadgeFill: colors.co,
    atBadgeText: colors.coInk,
    cardText: colors.text,
    cardTextMuted: colors.textMuted,
    cardTextDim: colors.textDim,
    cardTextFaint: colors.textFaint,
    conflict: colors.conflict,
    hatch: colors.hatch,
    hatchMark: colors.hatchMark,
    focusRing: colors.focusRing,
    dropTargetLine: colors.accentLiveLine,
    edge: colors.edge,
    edgeHover: colors.edgeHov,
    lineage: colors.co,
    lineageGlow: colors.coGlow,
    gapCut: colors.textFaint,
    gapCutHover: colors.text,
    gapText: colors.textFaint,
    gapTextHover: colors.textMuted,
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

  /// The card's fill, `--card-solid` (graph.css:2), also the legend's and the affordances'.
  final Color cardFill;

  /// The hovered and menu-open card's fill, `--card-solid-hi` (graph.css:4, :85).
  final Color cardFillHover;

  /// The card's 1 px border, `--border-strong` (graph.css:2).
  final Color cardBorder;

  /// The hovered and menu-open card's border, `--edge-hov` (graph.css:4, :85).
  final Color cardBorderHover;

  /// The selected card's border, `--accent-line` (graph.css:5, :23).
  final Color cardSelectedBorder;

  /// The working copy's border, `--co` (graph.css:6, :24).
  final Color workingCopyLine;

  /// The working copy's 135° tint, `--co-soft` (graph.css:6).
  final Color workingCopyTint;

  /// The @ badge's fill, `--co` (graph.css:38).
  final Color atBadgeFill;

  /// The @ badge's text, `--co-ink` (graph.css:38).
  final Color atBadgeText;

  /// The subject and the id's prefix, `--text` (graph.css:11, :35).
  final Color cardText;

  /// The immutable subject and the workspace tags, `--text-muted` (graph.css:13, :43).
  final Color cardTextMuted;

  /// The meta line, the placeholder subject and the flags, `--text-dim` (graph.css:12, :15, :19).
  final Color cardTextDim;

  /// The id's rest, "empty" and the add-bookmark glyph, `--text-faint` (graph.css:18, :34, :88).
  final Color cardTextFaint;

  /// The conflict flag, `--conflict` (graph.css:20).
  final Color conflict;

  /// The immutable card's hatch, `--hatch` (graph.css:109).
  final Color hatch;

  /// The hatch swatch's denser hatch, `--hatch-mark` (graph.css:110).
  final Color hatchMark;

  /// The keyboard focus outline, `--focus-ring` (DS tokens/states.css).
  final Color focusRing;

  /// A drop target card's border, `--accent-live-line` (Story 10.10; graph.css:8 `.zs-card.is-drop`).
  final Color dropTargetLine;

  /// An edge's 1.5 px stroke, `--edge` (DS components/graph/graph.css:65 `.zs-edge`).
  final Color edge;

  /// A hovered edge's stroke, `--edge-hov` (graph.css:67 `.zs-edge.is-hover`).
  final Color edgeHover;

  /// The @ lineage's 2.25 px stroke, `--co` (graph.css:68 `.zs-edge.is-wc`).
  final Color lineage;

  /// The @ lineage's 4 px drop-shadow glow, `--co-glow` (graph.css:68).
  final Color lineageGlow;

  /// A gap marker's two 1.5 px cuts, `--text-faint` (Story 10.19; graph.css:73 `.zs-gap-cut`).
  final Color gapCut;

  /// A hovered gap marker's cuts, `--text` (graph.css:75 `.zs-gap.is-hover`).
  final Color gapCutHover;

  /// An end stub's "~ elided", `--text-faint` (graph.css:74 `.zs-gap-txt`).
  final Color gapText;

  /// A hovered end stub's label, `--text-muted` (graph.css:75).
  final Color gapTextHover;

  /// The visible line a gap marker keeps to every card, bend, crossing and other mark, in px (Story 10.19; the
  /// export's CLEAR).
  final double gapClearance;

  @override
  GraphTheme copyWith({
    ZsCanvasGradient? canvas,
    Color? canvasBase,
    Color? dayGuide,
    Color? dayLabelText,
    Color? dayLabelFill,
    Color? dayLabelBorder,
    Color? cardFill,
    Color? cardFillHover,
    Color? cardBorder,
    Color? cardBorderHover,
    Color? cardSelectedBorder,
    Color? workingCopyLine,
    Color? workingCopyTint,
    Color? atBadgeFill,
    Color? atBadgeText,
    Color? cardText,
    Color? cardTextMuted,
    Color? cardTextDim,
    Color? cardTextFaint,
    Color? conflict,
    Color? hatch,
    Color? hatchMark,
    Color? focusRing,
    Color? dropTargetLine,
    Color? edge,
    Color? edgeHover,
    Color? lineage,
    Color? lineageGlow,
    Color? gapCut,
    Color? gapCutHover,
    Color? gapText,
    Color? gapTextHover,
    double? gapClearance,
  }) => GraphTheme(
    canvas: canvas ?? this.canvas,
    canvasBase: canvasBase ?? this.canvasBase,
    dayGuide: dayGuide ?? this.dayGuide,
    dayLabelText: dayLabelText ?? this.dayLabelText,
    dayLabelFill: dayLabelFill ?? this.dayLabelFill,
    dayLabelBorder: dayLabelBorder ?? this.dayLabelBorder,
    cardFill: cardFill ?? this.cardFill,
    cardFillHover: cardFillHover ?? this.cardFillHover,
    cardBorder: cardBorder ?? this.cardBorder,
    cardBorderHover: cardBorderHover ?? this.cardBorderHover,
    cardSelectedBorder: cardSelectedBorder ?? this.cardSelectedBorder,
    workingCopyLine: workingCopyLine ?? this.workingCopyLine,
    workingCopyTint: workingCopyTint ?? this.workingCopyTint,
    atBadgeFill: atBadgeFill ?? this.atBadgeFill,
    atBadgeText: atBadgeText ?? this.atBadgeText,
    cardText: cardText ?? this.cardText,
    cardTextMuted: cardTextMuted ?? this.cardTextMuted,
    cardTextDim: cardTextDim ?? this.cardTextDim,
    cardTextFaint: cardTextFaint ?? this.cardTextFaint,
    conflict: conflict ?? this.conflict,
    hatch: hatch ?? this.hatch,
    hatchMark: hatchMark ?? this.hatchMark,
    focusRing: focusRing ?? this.focusRing,
    dropTargetLine: dropTargetLine ?? this.dropTargetLine,
    edge: edge ?? this.edge,
    edgeHover: edgeHover ?? this.edgeHover,
    lineage: lineage ?? this.lineage,
    lineageGlow: lineageGlow ?? this.lineageGlow,
    gapCut: gapCut ?? this.gapCut,
    gapCutHover: gapCutHover ?? this.gapCutHover,
    gapText: gapText ?? this.gapText,
    gapTextHover: gapTextHover ?? this.gapTextHover,
    gapClearance: gapClearance ?? this.gapClearance,
  );

  @override
  GraphTheme lerp(GraphTheme? other, double t) {
    if (other == null) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return GraphTheme(
      canvas: ZsCanvasGradient.lerp(canvas, other.canvas, t),
      canvasBase: mix(canvasBase, other.canvasBase),
      dayGuide: mix(dayGuide, other.dayGuide),
      dayLabelText: mix(dayLabelText, other.dayLabelText),
      dayLabelFill: mix(dayLabelFill, other.dayLabelFill),
      dayLabelBorder: mix(dayLabelBorder, other.dayLabelBorder),
      cardFill: mix(cardFill, other.cardFill),
      cardFillHover: mix(cardFillHover, other.cardFillHover),
      cardBorder: mix(cardBorder, other.cardBorder),
      cardBorderHover: mix(cardBorderHover, other.cardBorderHover),
      cardSelectedBorder: mix(cardSelectedBorder, other.cardSelectedBorder),
      workingCopyLine: mix(workingCopyLine, other.workingCopyLine),
      workingCopyTint: mix(workingCopyTint, other.workingCopyTint),
      atBadgeFill: mix(atBadgeFill, other.atBadgeFill),
      atBadgeText: mix(atBadgeText, other.atBadgeText),
      cardText: mix(cardText, other.cardText),
      cardTextMuted: mix(cardTextMuted, other.cardTextMuted),
      cardTextDim: mix(cardTextDim, other.cardTextDim),
      cardTextFaint: mix(cardTextFaint, other.cardTextFaint),
      conflict: mix(conflict, other.conflict),
      hatch: mix(hatch, other.hatch),
      hatchMark: mix(hatchMark, other.hatchMark),
      focusRing: mix(focusRing, other.focusRing),
      dropTargetLine: mix(dropTargetLine, other.dropTargetLine),
      edge: mix(edge, other.edge),
      edgeHover: mix(edgeHover, other.edgeHover),
      lineage: mix(lineage, other.lineage),
      lineageGlow: mix(lineageGlow, other.lineageGlow),
      gapCut: mix(gapCut, other.gapCut),
      gapCutHover: mix(gapCutHover, other.gapCutHover),
      gapText: mix(gapText, other.gapText),
      gapTextHover: mix(gapTextHover, other.gapTextHover),
      gapClearance: gapClearance + (other.gapClearance - gapClearance) * t,
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
          other.dayLabelBorder == dayLabelBorder &&
          other.cardFill == cardFill &&
          other.cardFillHover == cardFillHover &&
          other.cardBorder == cardBorder &&
          other.cardBorderHover == cardBorderHover &&
          other.cardSelectedBorder == cardSelectedBorder &&
          other.workingCopyLine == workingCopyLine &&
          other.workingCopyTint == workingCopyTint &&
          other.atBadgeFill == atBadgeFill &&
          other.atBadgeText == atBadgeText &&
          other.cardText == cardText &&
          other.cardTextMuted == cardTextMuted &&
          other.cardTextDim == cardTextDim &&
          other.cardTextFaint == cardTextFaint &&
          other.conflict == conflict &&
          other.hatch == hatch &&
          other.hatchMark == hatchMark &&
          other.focusRing == focusRing &&
          other.dropTargetLine == dropTargetLine &&
          other.edge == edge &&
          other.edgeHover == edgeHover &&
          other.lineage == lineage &&
          other.lineageGlow == lineageGlow &&
          other.gapCut == gapCut &&
          other.gapCutHover == gapCutHover &&
          other.gapText == gapText &&
          other.gapTextHover == gapTextHover &&
          other.gapClearance == gapClearance;

  @override
  int get hashCode => Object.hashAll(<Object>[
    canvas,
    canvasBase,
    dayGuide,
    dayLabelText,
    dayLabelFill,
    dayLabelBorder,
    cardFill,
    cardFillHover,
    cardBorder,
    cardBorderHover,
    cardSelectedBorder,
    workingCopyLine,
    workingCopyTint,
    atBadgeFill,
    atBadgeText,
    cardText,
    cardTextMuted,
    cardTextDim,
    cardTextFaint,
    conflict,
    hatch,
    hatchMark,
    focusRing,
    dropTargetLine,
    edge,
    edgeHover,
    lineage,
    lineageGlow,
    gapCut,
    gapCutHover,
    gapText,
    gapTextHover,
    gapClearance,
  ]);
}
