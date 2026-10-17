// SPDX-License-Identifier: MIT

import 'dart:ui' show FontVariation, FontWeight, TextLeadingDistribution;

import 'package:flutter/painting.dart' show TextStyle;

/// The design system's type (DS tokens/typography.css:6-39): Inter for the UI, JetBrains Mono for anything jj prints
/// (ids, revsets, commands, paths, diffs, counts), Shippori Mincho only for 残心.
///
/// The roles are [TextStyle]s with the pubspec family names, `fontWeight` plus the variable fonts' `wght` axis
/// ([FontVariation.weight], as the splash does), CSS half-leading (`height` with [TextLeadingDistribution.even]) and
/// no colour — a view takes it from `ZsColors`. Flutter has no text-transform, so [caps] upper-cases the string.
// WHY: a namespace of constants like `ZI`; `caps` and `toCss` belong with them, and there is nothing to construct.
// ignore: avoid_classes_with_only_static_members
abstract final class ZsType {
  /// The pubspec family of the UI font (app/pubspec.yaml).
  static const sansFamily = 'Inter';

  /// The pubspec family of the mono font.
  static const monoFamily = 'JetBrainsMono';

  /// The pubspec family of Shippori Mincho, subset to 残心 and used for nothing else.
  static const kanjiFamily = 'ShipporiMincho';

  // ---- font stacks · DS tokens/typography.css:7-9 (the web stacks; Flutter uses the pubspec families) ----

  /// `--font-sans` (DS tokens/typography.css:7).
  static const fontSans = <String>[
    'Inter',
    '-apple-system',
    'BlinkMacSystemFont',
    'SF Pro Text',
    'Segoe UI',
    'system-ui',
    'sans-serif',
  ];

  /// `--font-mono` (DS tokens/typography.css:8).
  static const fontMono = <String>['JetBrains Mono', 'SF Mono', 'Menlo', 'ui-monospace', 'monospace'];

  /// `--font-kanji` (DS tokens/typography.css:9).
  static const fontKanji = <String>['Shippori Mincho', 'Hiragino Mincho ProN', 'Yu Mincho', 'serif'];

  // ---- sizes · DS tokens/typography.css:11-20 ----

  /// `--fs-2xs` (DS tokens/typography.css:11).
  static const fs2xs = 9.5;

  /// `--fs-xs` (DS tokens/typography.css:12).
  static const fsXs = 10.5;

  /// `--fs-sm` (DS tokens/typography.css:13).
  static const double fsSm = 11;

  /// `--fs-id` (DS tokens/typography.css:14).
  static const fsId = 11.5;

  /// `--fs-md` (DS tokens/typography.css:15).
  static const double fsMd = 12;

  /// `--fs-control` (DS tokens/typography.css:16).
  static const fsControl = 12.5;

  /// `--fs-base` (DS tokens/typography.css:17).
  static const double fsBase = 13;

  /// `--fs-lg` (DS tokens/typography.css:18).
  static const double fsLg = 15;

  /// `--fs-xl` (DS tokens/typography.css:19).
  static const double fsXl = 17;

  /// `--fs-2xl` (DS tokens/typography.css:20).
  static const double fs2xl = 18;

  // ---- weights, line heights, tracking · DS tokens/typography.css:22-24 ----

  /// `--fw-regular` (DS tokens/typography.css:22).
  static const FontWeight fwRegular = FontWeight.w400;

  /// `--fw-medium` (DS tokens/typography.css:22).
  static const FontWeight fwMedium = FontWeight.w500;

  /// `--fw-semibold` (DS tokens/typography.css:22).
  static const FontWeight fwSemibold = FontWeight.w600;

  /// `--fw-bold` (DS tokens/typography.css:22).
  static const FontWeight fwBold = FontWeight.w700;

  /// `--lh-tight` (DS tokens/typography.css:23).
  static const lhTight = 1.3;

  /// `--lh-snug` (DS tokens/typography.css:23).
  static const lhSnug = 1.35;

  /// `--lh-ui` (DS tokens/typography.css:23).
  static const lhUi = 1.5;

  /// `--lh-body` (DS tokens/typography.css:23).
  static const lhBody = 1.55;

  /// `--tracking-title` in em (DS tokens/typography.css:24).
  static const trackingTitle = -.012;

  /// `--tracking-dialog` in em (DS tokens/typography.css:24).
  static const trackingDialog = -.01;

  /// `--tracking-label` in em (DS tokens/typography.css:24).
  static const trackingLabel = -.005;

  /// `--tracking-caps` in em (DS tokens/typography.css:24).
  static const trackingCaps = .1;

  /// `--tracking-pill` in em (DS tokens/typography.css:24).
  static const trackingPill = .08;

  /// `--tracking-tagline` in em (DS tokens/typography.css:24).
  static const trackingTagline = .17;

  // ---- roles · DS tokens/typography.css:26-38 ----
  //
  // Letter spacing is em × size where the DS pairs a role with a tracking token — inspector title with
  // `--tracking-title` (DS ui_kits/desktop/kit.css), dialog title with `--tracking-dialog` and caps with
  // `--tracking-caps` (the components) — and 0 otherwise. Claude's proposal (Story 11.1), from the DS's pairings.

  /// `--type-inspector-title`: 600 18px/1.3 sans, tracked `--tracking-title` (DS tokens/typography.css:27).
  static const inspectorTitle = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation.weight(600)],
    fontSize: 18,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: trackingTitle * 18,
  );

  /// `--type-dialog-title`: 600 17px/1.3 sans, tracked `--tracking-dialog` (DS tokens/typography.css:28).
  static const dialogTitle = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation.weight(600)],
    fontSize: 17,
    height: 1.3,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: trackingDialog * 17,
  );

  /// `--type-panel-title`: 600 15px/1.35 sans (DS tokens/typography.css:29).
  static const panelTitle = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation.weight(600)],
    fontSize: 15,
    height: 1.35,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-card-subject`: 500 13px/1.35 sans (DS tokens/typography.css:30).
  static const cardSubject = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w500,
    fontVariations: <FontVariation>[FontVariation.weight(500)],
    fontSize: 13,
    height: 1.35,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-body`: 400 13px/1.55 sans (DS tokens/typography.css:31).
  static const body = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 13,
    height: 1.55,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-control`: 500 12.5px/1 sans (DS tokens/typography.css:32).
  static const control = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w500,
    fontVariations: <FontVariation>[FontVariation.weight(500)],
    fontSize: 12.5,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-secondary`: 400 12px/1.5 sans (DS tokens/typography.css:33).
  static const secondary = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 12,
    height: 1.5,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-meta`: 400 11px/1.35 sans (DS tokens/typography.css:34).
  static const meta = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 11,
    height: 1.35,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-caps`: 600 10.5px/1.2 sans, tracked `--tracking-caps`; pass the text through [caps]
  /// (DS tokens/typography.css:35).
  static const capsLabel = TextStyle(
    fontFamily: sansFamily,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation.weight(600)],
    fontSize: 10.5,
    height: 1.2,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: trackingCaps * 10.5,
  );

  /// `--type-id`: 400 11.5px/1.35 mono; Inter covers the glyphs JetBrains Mono lacks (DS tokens/typography.css:36).
  static const id = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: <String>[sansFamily],
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 11.5,
    height: 1.35,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-command`: 400 12px/1.35 mono (DS tokens/typography.css:37).
  static const command = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: <String>[sansFamily],
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 12,
    height: 1.35,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// `--type-code`: 400 11px/1.65 mono (DS tokens/typography.css:38).
  static const code = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: <String>[sansFamily],
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation.weight(400)],
    fontSize: 11,
    height: 1.65,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  /// The twelve roles, keyed by their CSS names.
  static const roles = <String, TextStyle>{
    '--type-inspector-title': inspectorTitle,
    '--type-dialog-title': dialogTitle,
    '--type-panel-title': panelTitle,
    '--type-card-subject': cardSubject,
    '--type-body': body,
    '--type-control': control,
    '--type-secondary': secondary,
    '--type-meta': meta,
    '--type-caps': capsLabel,
    '--type-id': id,
    '--type-command': command,
    '--type-code': code,
  };

  /// [text] as the caps role shows it: upper-cased, because Flutter has no text-transform.
  static String caps(String text) => text.toUpperCase();

  /// Every token as `'--name' → value`, for the DS parity test: a stack as its names joined by `, `, a weight as
  /// its number, a role as `(weight, size, line height, stack)`.
  static Map<String, Object> toCss() => <String, Object>{
    '--font-sans': fontSans.join(', '),
    '--font-mono': fontMono.join(', '),
    '--font-kanji': fontKanji.join(', '),
    '--fs-2xs': fs2xs,
    '--fs-xs': fsXs,
    '--fs-sm': fsSm,
    '--fs-id': fsId,
    '--fs-md': fsMd,
    '--fs-control': fsControl,
    '--fs-base': fsBase,
    '--fs-lg': fsLg,
    '--fs-xl': fsXl,
    '--fs-2xl': fs2xl,
    '--fw-regular': fwRegular.value,
    '--fw-medium': fwMedium.value,
    '--fw-semibold': fwSemibold.value,
    '--fw-bold': fwBold.value,
    '--lh-tight': lhTight,
    '--lh-snug': lhSnug,
    '--lh-ui': lhUi,
    '--lh-body': lhBody,
    '--tracking-title': trackingTitle,
    '--tracking-dialog': trackingDialog,
    '--tracking-label': trackingLabel,
    '--tracking-caps': trackingCaps,
    '--tracking-pill': trackingPill,
    '--tracking-tagline': trackingTagline,
    for (final MapEntry<String, TextStyle>(:key, :value) in roles.entries) key: _shorthand(value),
  };

  static Object _shorthand(TextStyle style) => (
    style.fontWeight?.value,
    style.fontSize,
    style.height,
    (style.fontFamily == monoFamily ? fontMono : fontSans).join(', '),
  );
}
