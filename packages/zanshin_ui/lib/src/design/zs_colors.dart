// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeExtension;

import 'zs_accents.dart';
import 'zs_appearance.dart';
import 'zs_values.dart';

/// The design system's theme-dependent colours: every colour and gradient token of DS tokens/colors.css,
/// tokens/states.css and tokens/accents.css, aliases included. Names follow the CSS (`--card-solid-hi` →
/// [cardSolidHi]); every value is the DS's fixed hex or rgba as written.
///
/// [night] and [paper] are the two themes under Multicolor; [ZsColors.resolve] adds the accent family and the
/// deltas in the cascade's order: theme → family → reduce transparency → increased contrast → inactive →
/// inactive × increased contrast. [of] falls back to [night] and never force-unwraps.
@immutable
class ZsColors extends ThemeExtension<ZsColors> {
  /// Creates a colour set; the app uses [night], [paper] and [ZsColors.resolve].
  const ZsColors({
    required this.night0,
    required this.night1,
    required this.night2,
    required this.night3,
    required this.night4,
    required this.night5,
    required this.nightIcon,
    required this.nightLift,
    required this.paper0,
    required this.paper1,
    required this.paper2,
    required this.paper3,
    required this.paper4,
    required this.paperInk,
    required this.umber,
    required this.gold50,
    required this.gold200,
    required this.gold400,
    required this.gold600,
    required this.goldInk,
    required this.saffron,
    required this.saffronPaper,
    required this.moon,
    required this.moonPaper,
    required this.green400,
    required this.green700,
    required this.red400,
    required this.red600,
    required this.amber400,
    required this.amberPaper,
    required this.tlClose,
    required this.tlMin,
    required this.tlZoom,
    required this.tlIdle,
    required this.tlRing,
    required this.canvas,
    required this.canvasBase,
    required this.gold,
    required this.cardSolid,
    required this.cardSolidHi,
    required this.hatch,
    required this.hatchMark,
    required this.bgCard,
    required this.bgCard2,
    required this.border,
    required this.borderStrong,
    required this.codeBg,
    required this.scrim,
    required this.flBg,
    required this.flBgStrong,
    required this.flBgSolid,
    required this.flBorder,
    required this.flSheen,
    required this.flHover,
    required this.flOn,
    required this.primaryAction,
    required this.atChrome,
    required this.atChromeEdge,
    required this.text,
    required this.textMuted,
    required this.textDim,
    required this.textFaint,
    required this.edge,
    required this.edgeHov,
    required this.co,
    required this.coSoft,
    required this.coDeep,
    required this.coGlow,
    required this.coText,
    required this.coInk,
    required this.accent,
    required this.accentInk,
    required this.accentLine,
    required this.accentText,
    required this.accentSoft,
    required this.accentSoftHi,
    required this.accentRing,
    required this.accentSelect,
    required this.accentLiveLine,
    required this.accentLiveRing,
    required this.accentLiveText,
    required this.statusM,
    required this.statusMBg,
    required this.hunk,
    required this.hunkBg,
    required this.remote,
    required this.projClean,
    required this.projDirty,
    required this.projAhead,
    required this.projBehind,
    required this.projDiverged,
    required this.projConflict,
    required this.projMissing,
    required this.projSyncing,
    required this.projStale,
    required this.add,
    required this.addBg,
    required this.rem,
    required this.remBg,
    required this.addBgHi,
    required this.addEdge,
    required this.addRing,
    required this.conflict,
    required this.warn,
    required this.warnBg,
    required this.focusRing,
    required this.flPress,
    required this.flOnHover,
    required this.fillOnHover,
    required this.fillOnPress,
    required this.addInk,
    required this.fieldBg,
    required this.segInsetBg,
    required this.primaryFillA,
    required this.primaryFillB,
    required this.primaryFillAHover,
    required this.primaryFillBHover,
    required this.primaryFillAPress,
    required this.primaryFillBPress,
    required this.primaryRing,
    required this.primaryRingHover,
    required this.primaryIcon,
    required this.destructiveFillA,
    required this.destructiveFillB,
    required this.destructiveFillAHover,
    required this.destructiveFillBHover,
    required this.destructiveFillAPress,
    required this.destructiveFillBPress,
    required this.destructiveRing,
    required this.destructiveRingHover,
    required this.dangerHover,
    required this.dangerPress,
    required this.remBgHover,
    required this.remBgPress,
    required this.error,
    required this.errorRing,
    required this.thumb,
    required this.thumbEdge,
    required this.track,
    required this.trackHover,
    required this.trackEdge,
    required this.trackEdgeHover,
    required this.tick,
    required this.progressTrack,
    required this.scrollThumb,
    required this.scrollThumbHover,
    required this.scrollThumbDrag,
    required this.scrollTrack,
    required this.tooltipBg,
    required this.tooltipBorder,
    required this.skeleton,
    required this.skeletonHi,
    required this.selectionTextAlt,
    required this.selectInactive,
  });

  /// The colours [appearance] shows, resolved like the DS's cascade (DS styles.css:1-11).
  factory ZsColors.resolve(ZsAppearance appearance) {
    final onPaper = appearance.theme == ZsTheme.paper;
    ZsColors colors = onPaper ? ZsColors.paper : ZsColors.night;
    if (appearance.family != ZsAccentFamily.multicolor) {
      // DS tokens/accents.css:28-53: the family, then the derived `--focus-ring`.
      final ZsAccentTokens family = appearance.family.tokensIn(appearance.theme);
      colors = colors.copyWith(
        accent: family.accent,
        accentInk: family.accentInk,
        accentLine: family.accentLine,
        accentText: family.accentText,
        accentSoft: family.accentSoft,
        accentSoftHi: family.accentSoftHi,
        accentRing: family.accentRing,
        accentSelect: family.accentSelect,
        accentLiveLine: family.accentLiveLine,
        accentLiveRing: family.accentLiveRing,
        accentLiveText: family.accentLiveText,
        focusRing: family.accentLine,
      );
    }
    if (appearance.reduceTransparency) {
      // DS tokens/transparency.css:9 (paper :10).
      colors = onPaper
          ? colors.copyWith(
              flBg: const Color(0xFFFFFDFA),
              flBgStrong: const Color(0xFFFFFDFA),
              scrim: const Color.fromRGBO(58, 46, 34, .28),
            )
          : colors.copyWith(
              flBg: const Color(0xFF1A1F35),
              flBgStrong: const Color(0xFF1A1F35),
              scrim: const Color.fromRGBO(7, 9, 20, .62),
            );
    }
    if (appearance.increasedContrast) {
      // DS tokens/contrast.css:21 (paper :22).
      colors = onPaper
          ? colors.copyWith(
              border: const Color(0xFF8F877F),
              borderStrong: const Color(0xFF867E75),
              flBorder: const Color(0xFF867E75),
              edge: const Color(0xFF857D74),
              edgeHov: const Color(0xFF5F5852),
              track: const Color(0xFFEFEBE6),
              trackHover: const Color(0xFFEFEBE6),
              trackEdge: const Color(0xFF867E75),
              trackEdgeHover: const Color(0xFF5F5852),
              tick: const Color(0xFF8A8279),
              scrollThumb: const Color(0xFF8A8279),
              scrollThumbHover: const Color(0xFF6F675F),
              scrollThumbDrag: const Color(0xFF5F5852),
              textDim: const Color(0xFF5F5852),
              textFaint: const Color(0xFF655E57),
              flBg: const Color(0xFFFFFDFA),
              flBgStrong: const Color(0xFFFFFDFA),
              scrim: const Color.fromRGBO(58, 46, 34, .36),
            )
          : colors.copyWith(
              border: const Color(0xFF6F7792),
              borderStrong: const Color(0xFF78809C),
              flBorder: const Color(0xFF78809C),
              edge: const Color(0xFF7C84A0),
              edgeHov: const Color(0xFFA6ADC6),
              track: const Color(0xFF232941),
              trackHover: const Color(0xFF232941),
              trackEdge: const Color(0xFF78809C),
              trackEdgeHover: const Color(0xFFA6ADC6),
              tick: const Color(0xFF767E9A),
              scrollThumb: const Color(0xFF767E9A),
              scrollThumbHover: const Color(0xFF8F97B2),
              scrollThumbDrag: const Color(0xFFA6ADC6),
              textDim: const Color(0xFFAAB1CA),
              textFaint: const Color(0xFFA3AAC3),
              flBg: const Color(0xFF1A1F35),
              flBgStrong: const Color(0xFF1A1F35),
              scrim: const Color.fromRGBO(7, 9, 20, .7),
            );
    }
    if (appearance.inactive) {
      // DS tokens/inactive.css:17 (paper :18).
      colors = onPaper
          ? colors.copyWith(
              accent: const Color(0xFFA69E96),
              accentInk: const Color(0xFF26242C),
              accentLine: const Color(0xFF867E75),
              accentText: const Color(0xFF514C47),
              accentSoft: const Color.fromRGBO(58, 46, 34, .07),
              accentSoftHi: const Color.fromRGBO(58, 46, 34, .11),
              accentRing: const Color.fromRGBO(58, 46, 34, .14),
              accentSelect: const Color.fromRGBO(58, 46, 34, .12),
              focusRing: const Color(0x00000000),
            )
          : colors.copyWith(
              accent: const Color(0xFF8A90A8),
              accentInk: const Color(0xFF141831),
              accentLine: const Color(0xFF8189A5),
              accentText: const Color(0xFFB3B9D0),
              accentSoft: const Color.fromRGBO(231, 233, 242, .08),
              accentSoftHi: const Color.fromRGBO(231, 233, 242, .14),
              accentRing: const Color.fromRGBO(231, 233, 242, .16),
              accentSelect: const Color.fromRGBO(231, 233, 242, .16),
              focusRing: const Color(0x00000000),
            );
    }
    if (appearance.inactive && appearance.increasedContrast) {
      // DS tokens/inactive.css:26 (paper :27): the neutral line would equal the contrast card edge.
      colors = onPaper
          ? colors.copyWith(accentLine: const Color(0xFF26242C))
          : colors.copyWith(accentLine: const Color(0xFFE7E9F2));
    }
    return colors;
  }

  /// Night under Multicolor (DS tokens/colors.css:9-77, tokens/states.css:7-74).
  static const night = ZsColors(
    night0: Color(0xFF0E1224),
    night1: Color(0xFF12162A),
    night2: Color(0xFF131831),
    night3: Color(0xFF1A1F35),
    night4: Color(0xFF1C2138),
    night5: Color(0xFF1F2540),
    nightIcon: Color(0xFF1D2540),
    nightLift: Color(0xFF6078B2),
    paper0: Color(0xFFFFFDFA),
    paper1: Color(0xFFF7F4F0),
    paper2: Color(0xFFF0ECE7),
    paper3: Color(0xFFE8E3DD),
    paper4: Color(0xFFCBC7C2),
    paperInk: Color(0xFF26242C),
    umber: Color(0xFF3A2E22),
    gold50: Color(0xFFFFF6E4),
    gold200: Color(0xFFF4CF80),
    gold400: Color(0xFFDCA85B),
    gold600: Color(0xFFB58346),
    goldInk: Color(0xFF26304D),
    saffron: Color(0xFFF2A618),
    saffronPaper: Color(0xFFA56205),
    moon: Color(0xFFAEBCEC),
    moonPaper: Color(0xFF4757A1),
    green400: Color(0xFF4ADE80),
    green700: Color(0xFF1A7F45),
    red400: Color(0xFFF87171),
    red600: Color(0xFFC23A3A),
    amber400: Color(0xFFFBBF24),
    amberPaper: Color(0xFF915C05),
    tlClose: Color(0xFFFF5F57),
    tlMin: Color(0xFFFEBC2E),
    tlZoom: Color(0xFF28C840),
    tlIdle: Color.fromRGBO(255, 255, 255, .14),
    tlRing: Color.fromRGBO(255, 255, 255, .26),
    canvas: ZsCanvasGradient(
      radial: ZsRadialGradient(
        width: 115,
        height: 85,
        centerX: 10,
        centerY: -12,
        stops: <ZsGradientStop>[
          ZsGradientStop(Color.fromRGBO(96, 120, 178, .24)),
          ZsGradientStop(Color.fromRGBO(96, 120, 178, 0), percent: 62),
        ],
      ),
      linear: ZsLinearGradient(
        angle: 165,
        stops: <ZsGradientStop>[
          ZsGradientStop(Color(0xFF1A2038)),
          ZsGradientStop(Color(0xFF12162A), percent: 68),
          ZsGradientStop(Color(0xFF0E1224)),
        ],
      ),
    ),
    canvasBase: Color(0xFF12162A),
    gold: Color(0xFFDCA85B),
    cardSolid: Color(0xFF1A1F35),
    cardSolidHi: Color(0xFF1F2540),
    hatch: Color.fromRGBO(231, 233, 242, .07),
    hatchMark: Color.fromRGBO(231, 233, 242, .30),
    bgCard: Color.fromRGBO(255, 255, 255, .045),
    bgCard2: Color.fromRGBO(255, 255, 255, .075),
    border: Color.fromRGBO(255, 255, 255, .07),
    borderStrong: Color.fromRGBO(255, 255, 255, .14),
    codeBg: Color.fromRGBO(8, 10, 22, .42),
    scrim: Color.fromRGBO(7, 9, 20, .48),
    flBg: Color.fromRGBO(26, 31, 56, .66),
    flBgStrong: Color.fromRGBO(24, 29, 52, .86),
    flBgSolid: Color(0xFF1A1F35),
    flBorder: Color.fromRGBO(255, 255, 255, .09),
    flSheen: ZsLinearGradient(
      angle: 180,
      stops: <ZsGradientStop>[
        ZsGradientStop(Color.fromRGBO(255, 255, 255, .045)),
        ZsGradientStop(Color.fromRGBO(255, 255, 255, 0), px: 46),
      ],
    ),
    flHover: Color.fromRGBO(255, 255, 255, .07),
    flOn: Color.fromRGBO(255, 255, 255, .11),
    primaryAction: Color(0xFFDCA85B),
    atChrome: Color(0xFFDCA85B),
    atChromeEdge: Color.fromRGBO(220, 168, 91, .42),
    text: Color(0xFFE7E9F2),
    textMuted: Color(0xFFB3B9D0),
    textDim: Color(0xFF9299B4),
    textFaint: Color(0xFF8189A5),
    edge: Color.fromRGBO(214, 222, 245, .34),
    edgeHov: Color.fromRGBO(234, 238, 250, .72),
    co: Color(0xFFF2A618),
    coSoft: Color.fromRGBO(242, 166, 24, .14),
    coDeep: Color.fromRGBO(242, 166, 24, .55),
    coGlow: Color.fromRGBO(242, 166, 24, .30),
    coText: Color(0xFFF8C885),
    coInk: Color(0xFF1A1206),
    accent: Color(0xFFAEBCEC),
    accentInk: Color(0xFF141831),
    accentLine: Color(0xFFAEBCEC),
    accentText: Color(0xFFAEBCEC),
    accentSoft: Color.fromRGBO(174, 188, 236, .14),
    accentSoftHi: Color.fromRGBO(174, 188, 236, .24),
    accentRing: Color.fromRGBO(174, 188, 236, .3),
    accentSelect: Color.fromRGBO(174, 188, 236, .34),
    accentLiveLine: Color(0xFFAEBCEC),
    accentLiveRing: Color.fromRGBO(174, 188, 236, .3),
    accentLiveText: Color(0xFFAEBCEC),
    statusM: Color(0xFFAEBCEC),
    statusMBg: Color.fromRGBO(174, 188, 236, .14),
    hunk: Color(0xFFAEBCEC),
    hunkBg: Color.fromRGBO(174, 188, 236, .14),
    remote: Color(0xFFAEBCEC),
    projClean: Color(0xFF9CA3AF),
    projDirty: Color(0xFFFACC15),
    projAhead: Color(0xFF4ADE80),
    projBehind: Color(0xFF60A5FA),
    projDiverged: Color(0xFFFB923C),
    projConflict: Color(0xFFF87171),
    projMissing: Color(0xFF71717A),
    projSyncing: Color(0xFFA78BFA),
    projStale: Color(0xFF22D3EE),
    add: Color(0xFF4ADE80),
    addBg: Color.fromRGBO(74, 222, 128, .13),
    rem: Color(0xFFF87171),
    remBg: Color.fromRGBO(248, 113, 113, .13),
    addBgHi: Color.fromRGBO(74, 222, 128, .18),
    addEdge: Color.fromRGBO(74, 222, 128, .24),
    addRing: Color.fromRGBO(74, 222, 128, .35),
    conflict: Color(0xFFFBBF24),
    warn: Color(0xFFF7C243),
    warnBg: Color.fromRGBO(234, 181, 50, .16),
    focusRing: Color(0xFFAEBCEC),
    flPress: Color.fromRGBO(255, 255, 255, .15),
    flOnHover: Color.fromRGBO(255, 255, 255, .13),
    fillOnHover: Color.fromRGBO(255, 255, 255, .14),
    fillOnPress: Color.fromRGBO(255, 255, 255, .26),
    addInk: Color(0xFF06210F),
    fieldBg: Color.fromRGBO(8, 10, 22, .45),
    segInsetBg: Color.fromRGBO(0, 0, 0, .2),
    primaryFillA: Color.fromRGBO(220, 168, 91, .22),
    primaryFillB: Color.fromRGBO(220, 168, 91, .08),
    primaryFillAHover: Color.fromRGBO(220, 168, 91, .30),
    primaryFillBHover: Color.fromRGBO(220, 168, 91, .12),
    primaryFillAPress: Color.fromRGBO(220, 168, 91, .38),
    primaryFillBPress: Color.fromRGBO(220, 168, 91, .17),
    primaryRing: Color.fromRGBO(220, 168, 91, .55),
    primaryRingHover: Color(0xFFDCA85B),
    primaryIcon: Color(0xFFDCA85B),
    destructiveFillA: Color.fromRGBO(248, 113, 113, .30),
    destructiveFillB: Color.fromRGBO(248, 113, 113, .14),
    destructiveFillAHover: Color.fromRGBO(248, 113, 113, .38),
    destructiveFillBHover: Color.fromRGBO(248, 113, 113, .20),
    destructiveFillAPress: Color.fromRGBO(248, 113, 113, .46),
    destructiveFillBPress: Color.fromRGBO(248, 113, 113, .26),
    destructiveRing: Color.fromRGBO(248, 113, 113, .70),
    destructiveRingHover: Color(0xFFF87171),
    dangerHover: Color.fromRGBO(248, 113, 113, .10),
    dangerPress: Color.fromRGBO(248, 113, 113, .15),
    remBgHover: Color.fromRGBO(248, 113, 113, .20),
    remBgPress: Color.fromRGBO(248, 113, 113, .26),
    error: Color(0xFFF87171),
    errorRing: Color.fromRGBO(248, 113, 113, .30),
    thumb: Color(0xFFF4F5FA),
    thumbEdge: Color.fromRGBO(8, 10, 22, .35),
    track: Color.fromRGBO(255, 255, 255, .14),
    trackHover: Color.fromRGBO(255, 255, 255, .2),
    trackEdge: Color(0x00000000),
    trackEdgeHover: Color(0x00000000),
    tick: Color.fromRGBO(255, 255, 255, .22),
    progressTrack: Color.fromRGBO(255, 255, 255, .10),
    scrollThumb: Color.fromRGBO(255, 255, 255, .22),
    scrollThumbHover: Color.fromRGBO(255, 255, 255, .34),
    scrollThumbDrag: Color.fromRGBO(255, 255, 255, .44),
    scrollTrack: Color.fromRGBO(255, 255, 255, .05),
    tooltipBg: Color(0xFF262C48),
    tooltipBorder: Color.fromRGBO(255, 255, 255, .12),
    skeleton: Color.fromRGBO(255, 255, 255, .06),
    skeletonHi: Color.fromRGBO(255, 255, 255, .11),
    selectionTextAlt: Color(0xFF141831),
    selectInactive: Color.fromRGBO(231, 233, 242, .16),
  );

  /// Paper under Multicolor (DS tokens/colors.css:79-111, tokens/states.css:75-100;
  /// the base palette cascades from :root).
  static const paper = ZsColors(
    night0: Color(0xFF0E1224),
    night1: Color(0xFF12162A),
    night2: Color(0xFF131831),
    night3: Color(0xFF1A1F35),
    night4: Color(0xFF1C2138),
    night5: Color(0xFF1F2540),
    nightIcon: Color(0xFF1D2540),
    nightLift: Color(0xFF6078B2),
    paper0: Color(0xFFFFFDFA),
    paper1: Color(0xFFF7F4F0),
    paper2: Color(0xFFF0ECE7),
    paper3: Color(0xFFE8E3DD),
    paper4: Color(0xFFCBC7C2),
    paperInk: Color(0xFF26242C),
    umber: Color(0xFF3A2E22),
    gold50: Color(0xFFFFF6E4),
    gold200: Color(0xFFF4CF80),
    gold400: Color(0xFFDCA85B),
    gold600: Color(0xFFB58346),
    goldInk: Color(0xFF26304D),
    saffron: Color(0xFFF2A618),
    saffronPaper: Color(0xFFA56205),
    moon: Color(0xFFAEBCEC),
    moonPaper: Color(0xFF4757A1),
    green400: Color(0xFF4ADE80),
    green700: Color(0xFF1A7F45),
    red400: Color(0xFFF87171),
    red600: Color(0xFFC23A3A),
    amber400: Color(0xFFFBBF24),
    amberPaper: Color(0xFF915C05),
    tlClose: Color(0xFFFF5F57),
    tlMin: Color(0xFFFEBC2E),
    tlZoom: Color(0xFF28C840),
    tlIdle: Color.fromRGBO(58, 46, 34, .22),
    tlRing: Color.fromRGBO(58, 46, 34, .30),
    canvas: ZsCanvasGradient(
      radial: ZsRadialGradient(
        width: 115,
        height: 85,
        centerX: 10,
        centerY: -12,
        stops: <ZsGradientStop>[
          ZsGradientStop(Color.fromRGBO(220, 168, 91, .20)),
          ZsGradientStop(Color.fromRGBO(220, 168, 91, 0), percent: 62),
        ],
      ),
      linear: ZsLinearGradient(
        angle: 165,
        stops: <ZsGradientStop>[
          ZsGradientStop(Color(0xFFF7F4F0)),
          ZsGradientStop(Color(0xFFF0ECE7), percent: 68),
          ZsGradientStop(Color(0xFFE8E3DD)),
        ],
      ),
    ),
    canvasBase: Color(0xFFF0ECE7),
    gold: Color(0xFFDCA85B),
    cardSolid: Color(0xFFFFFDFA),
    cardSolidHi: Color(0xFFFFFFFF),
    hatch: Color.fromRGBO(38, 36, 44, .07),
    hatchMark: Color.fromRGBO(38, 36, 44, .30),
    bgCard: Color.fromRGBO(255, 253, 250, .90),
    bgCard2: Color.fromRGBO(58, 46, 34, .07),
    border: Color.fromRGBO(58, 46, 34, .12),
    borderStrong: Color.fromRGBO(58, 46, 34, .22),
    codeBg: Color.fromRGBO(255, 255, 255, .66),
    scrim: Color.fromRGBO(58, 46, 34, .18),
    flBg: Color.fromRGBO(255, 253, 250, .74),
    flBgStrong: Color.fromRGBO(255, 253, 250, .9),
    flBgSolid: Color(0xFFFFFDFA),
    flBorder: Color.fromRGBO(58, 46, 34, .12),
    flSheen: ZsLinearGradient(
      angle: 180,
      stops: <ZsGradientStop>[
        ZsGradientStop(Color.fromRGBO(255, 255, 255, .6)),
        ZsGradientStop(Color.fromRGBO(255, 255, 255, 0), px: 46),
      ],
    ),
    flHover: Color.fromRGBO(58, 46, 34, .06),
    flOn: Color.fromRGBO(58, 46, 34, .1),
    primaryAction: Color(0xFFA06605),
    atChrome: Color(0xFFA06605),
    atChromeEdge: Color.fromRGBO(160, 102, 5, .45),
    text: Color(0xFF26242C),
    textMuted: Color(0xFF514C47),
    textDim: Color(0xFF5F5852),
    textFaint: Color(0xFF736C65),
    edge: Color.fromRGBO(58, 46, 34, .30),
    edgeHov: Color.fromRGBO(58, 46, 34, .62),
    co: Color(0xFFA56205),
    coSoft: Color.fromRGBO(165, 98, 5, .10),
    coDeep: Color.fromRGBO(165, 98, 5, .45),
    coGlow: Color.fromRGBO(165, 98, 5, .22),
    coText: Color(0xFF7A4802),
    coInk: Color(0xFFFFF8EC),
    accent: Color(0xFF4757A1),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFF4757A1),
    accentText: Color(0xFF4757A1),
    accentSoft: Color.fromRGBO(71, 87, 161, .09),
    accentSoftHi: Color.fromRGBO(71, 87, 161, .16),
    accentRing: Color.fromRGBO(71, 87, 161, .22),
    accentSelect: Color.fromRGBO(71, 87, 161, .22),
    accentLiveLine: Color(0xFF4757A1),
    accentLiveRing: Color.fromRGBO(71, 87, 161, .22),
    accentLiveText: Color(0xFF4757A1),
    statusM: Color(0xFF4757A1),
    statusMBg: Color.fromRGBO(71, 87, 161, .09),
    hunk: Color(0xFF4757A1),
    hunkBg: Color.fromRGBO(71, 87, 161, .09),
    remote: Color(0xFF4757A1),
    projClean: Color(0xFF84868C),
    projDirty: Color(0xFFA38207),
    projAhead: Color(0xFF218A45),
    projBehind: Color(0xFF0F74C5),
    projDiverged: Color(0xFFC75D04),
    projConflict: Color(0xFFC23A3A),
    projMissing: Color(0xFF6F7178),
    projSyncing: Color(0xFF795BBF),
    projStale: Color(0xFF0E7490),
    add: Color(0xFF1A7F45),
    addBg: Color.fromRGBO(26, 127, 69, .10),
    rem: Color(0xFFC23A3A),
    remBg: Color.fromRGBO(194, 58, 58, .09),
    addBgHi: Color.fromRGBO(26, 127, 69, .14),
    addEdge: Color.fromRGBO(26, 127, 69, .28),
    addRing: Color.fromRGBO(26, 127, 69, .35),
    conflict: Color(0xFF915C05),
    warn: Color(0xFF895604),
    warnBg: Color.fromRGBO(234, 181, 50, .16),
    focusRing: Color(0xFF4757A1),
    flPress: Color.fromRGBO(58, 46, 34, .14),
    flOnHover: Color.fromRGBO(58, 46, 34, .12),
    fillOnHover: Color.fromRGBO(0, 0, 0, .10),
    fillOnPress: Color.fromRGBO(0, 0, 0, .18),
    addInk: Color(0xFFFFFFFF),
    fieldBg: Color.fromRGBO(255, 255, 255, .9),
    segInsetBg: Color.fromRGBO(58, 46, 34, .07),
    primaryFillA: Color.fromRGBO(160, 102, 5, .20),
    primaryFillB: Color.fromRGBO(160, 102, 5, .07),
    primaryFillAHover: Color.fromRGBO(160, 102, 5, .27),
    primaryFillBHover: Color.fromRGBO(160, 102, 5, .11),
    primaryFillAPress: Color.fromRGBO(160, 102, 5, .34),
    primaryFillBPress: Color.fromRGBO(160, 102, 5, .15),
    primaryRing: Color.fromRGBO(160, 102, 5, .80),
    primaryRingHover: Color(0xFFA06605),
    primaryIcon: Color(0xFFA06605),
    destructiveFillA: Color.fromRGBO(194, 58, 58, .16),
    destructiveFillB: Color.fromRGBO(194, 58, 58, .07),
    destructiveFillAHover: Color.fromRGBO(194, 58, 58, .22),
    destructiveFillBHover: Color.fromRGBO(194, 58, 58, .11),
    destructiveFillAPress: Color.fromRGBO(194, 58, 58, .28),
    destructiveFillBPress: Color.fromRGBO(194, 58, 58, .15),
    destructiveRing: Color.fromRGBO(194, 58, 58, .80),
    destructiveRingHover: Color(0xFFC23A3A),
    dangerHover: Color.fromRGBO(194, 58, 58, .09),
    dangerPress: Color.fromRGBO(194, 58, 58, .13),
    remBgHover: Color.fromRGBO(194, 58, 58, .14),
    remBgPress: Color.fromRGBO(194, 58, 58, .19),
    error: Color(0xFFC23A3A),
    errorRing: Color.fromRGBO(194, 58, 58, .22),
    thumb: Color(0xFFFFFFFF),
    thumbEdge: Color(0xFF958D85),
    track: Color.fromRGBO(58, 46, 34, .18),
    trackHover: Color.fromRGBO(58, 46, 34, .26),
    trackEdge: Color(0x00000000),
    trackEdgeHover: Color(0x00000000),
    tick: Color.fromRGBO(58, 46, 34, .3),
    progressTrack: Color.fromRGBO(58, 46, 34, .12),
    scrollThumb: Color.fromRGBO(58, 46, 34, .28),
    scrollThumbHover: Color.fromRGBO(58, 46, 34, .4),
    scrollThumbDrag: Color.fromRGBO(58, 46, 34, .5),
    scrollTrack: Color.fromRGBO(58, 46, 34, .05),
    tooltipBg: Color(0xFFFFFFFF),
    tooltipBorder: Color.fromRGBO(58, 46, 34, .18),
    skeleton: Color.fromRGBO(58, 46, 34, .07),
    skeletonHi: Color.fromRGBO(58, 46, 34, .12),
    selectionTextAlt: Color(0xFFFFFFFF),
    selectInactive: Color.fromRGBO(58, 46, 34, .12),
  );

  /// The colours of the nearest [Theme], or [night] when it carries none.
  static ZsColors of(BuildContext context) => Theme.of(context).extension<ZsColors>() ?? night;

  // ---- base palette · DS tokens/colors.css:11-23 ----

  /// `--night-0` (DS tokens/colors.css:12).
  final Color night0;

  /// `--night-1` (DS tokens/colors.css:12).
  final Color night1;

  /// `--night-2` (DS tokens/colors.css:12).
  final Color night2;

  /// `--night-3` (DS tokens/colors.css:12).
  final Color night3;

  /// `--night-4` (DS tokens/colors.css:12).
  final Color night4;

  /// `--night-5` (DS tokens/colors.css:12).
  final Color night5;

  /// `--night-icon` (DS tokens/colors.css:12).
  final Color nightIcon;

  /// `--night-lift` (DS tokens/colors.css:12).
  final Color nightLift;

  /// `--paper-0` (DS tokens/colors.css:13).
  final Color paper0;

  /// `--paper-1` (DS tokens/colors.css:13).
  final Color paper1;

  /// `--paper-2` (DS tokens/colors.css:13).
  final Color paper2;

  /// `--paper-3` (DS tokens/colors.css:13).
  final Color paper3;

  /// `--paper-4` (DS tokens/colors.css:13).
  final Color paper4;

  /// `--paper-ink` (DS tokens/colors.css:13).
  final Color paperInk;

  /// `--umber` (DS tokens/colors.css:13).
  final Color umber;

  /// `--gold-50` (DS tokens/colors.css:14).
  final Color gold50;

  /// `--gold-200` (DS tokens/colors.css:14).
  final Color gold200;

  /// `--gold-400` (DS tokens/colors.css:14).
  final Color gold400;

  /// `--gold-600` (DS tokens/colors.css:14).
  final Color gold600;

  /// `--gold-ink` (DS tokens/colors.css:14).
  final Color goldInk;

  /// `--saffron` (DS tokens/colors.css:16).
  final Color saffron;

  /// `--saffron-paper` (DS tokens/colors.css:16).
  final Color saffronPaper;

  /// `--moon` (DS tokens/colors.css:17).
  final Color moon;

  /// `--moon-paper` (DS tokens/colors.css:17).
  final Color moonPaper;

  /// `--green-400` (DS tokens/colors.css:18).
  final Color green400;

  /// `--green-700` (DS tokens/colors.css:18).
  final Color green700;

  /// `--red-400` (DS tokens/colors.css:18).
  final Color red400;

  /// `--red-600` (DS tokens/colors.css:18).
  final Color red600;

  /// `--amber-400` (DS tokens/colors.css:18).
  final Color amber400;

  /// `--amber-paper` (DS tokens/colors.css:18).
  final Color amberPaper;

  /// `--tl-close` (DS tokens/colors.css:22).
  final Color tlClose;

  /// `--tl-min` (DS tokens/colors.css:22).
  final Color tlMin;

  /// `--tl-zoom` (DS tokens/colors.css:22).
  final Color tlZoom;

  /// `--tl-idle` (DS tokens/colors.css:22; paper :81).
  final Color tlIdle;

  /// `--tl-ring` (DS tokens/colors.css:22; paper :81).
  final Color tlRing;

  // ---- window canvas · DS tokens/colors.css:24-28 ----

  /// `--canvas` (DS tokens/colors.css:25; paper :82).
  final ZsCanvasGradient canvas;

  /// `--canvas-base` (DS tokens/colors.css:26; paper :83).
  final Color canvasBase;

  /// `--gold` (DS tokens/colors.css:27).
  final Color gold;

  // ---- solid surfaces · DS tokens/colors.css:29-34 ----

  /// `--card-solid` (DS tokens/colors.css:30; paper :84).
  final Color cardSolid;

  /// `--card-solid-hi` (DS tokens/colors.css:30; paper :84).
  final Color cardSolidHi;

  /// `--hatch` (DS tokens/colors.css:33; paper :88): the immutable card's 135° hatch, 7% of `--text`.
  final Color hatch;

  /// `--hatch-mark` (DS tokens/colors.css:33; paper :88): the denser hatch of the hatch swatch, 30% of `--text`.
  final Color hatchMark;

  /// `--bg-card` (DS tokens/colors.css:31; paper :85).
  final Color bgCard;

  /// `--bg-card-2` (DS tokens/colors.css:31; paper :85).
  final Color bgCard2;

  /// `--border` (DS tokens/colors.css:32; paper :86).
  final Color border;

  /// `--border-strong` (DS tokens/colors.css:32; paper :86).
  final Color borderStrong;

  /// `--code-bg` (DS tokens/colors.css:33; paper :87).
  final Color codeBg;

  /// `--scrim` (DS tokens/colors.css:33; paper :87).
  final Color scrim;

  // ---- floating glass · DS tokens/colors.css:35-38 ----

  /// `--fl-bg` (DS tokens/colors.css:36; paper :88).
  final Color flBg;

  /// `--fl-bg-strong` (DS tokens/colors.css:36; paper :88).
  final Color flBgStrong;

  /// `--fl-bg-solid` (DS tokens/colors.css:36; paper :88).
  final Color flBgSolid;

  /// `--fl-border` (DS tokens/colors.css:36; paper :88).
  final Color flBorder;

  /// `--fl-sheen` (DS tokens/colors.css:37; paper :89).
  final ZsLinearGradient flSheen;

  /// `--fl-hover` (DS tokens/colors.css:38; paper :90).
  final Color flHover;

  /// `--fl-on` (DS tokens/colors.css:38; paper :90).
  final Color flOn;

  // ---- gold split by role · DS tokens/colors.css:39-43 ----

  /// `--primary-action` (DS tokens/colors.css:40; paper :91).
  final Color primaryAction;

  /// `--at-chrome` (DS tokens/colors.css:41; paper :91).
  final Color atChrome;

  /// `--at-chrome-edge` (DS tokens/colors.css:42; paper :91).
  final Color atChromeEdge;

  // ---- text ladder · DS tokens/colors.css:44-46 ----

  /// `--text` (DS tokens/colors.css:45; paper :93).
  final Color text;

  /// `--text-muted` (DS tokens/colors.css:45; paper :93).
  final Color textMuted;

  /// `--text-dim` (DS tokens/colors.css:45; paper :93).
  final Color textDim;

  /// `--text-faint` (DS tokens/colors.css:45; paper :93).
  final Color textFaint;

  // ---- graph lines · DS tokens/colors.css:47-49 ----

  /// `--edge` (DS tokens/colors.css:48; paper :94).
  final Color edge;

  /// `--edge-hov` (DS tokens/colors.css:48; paper :94).
  final Color edgeHov;

  // ---- @ working copy (saffron) · DS tokens/colors.css:50-52 ----

  /// `--co` (DS tokens/colors.css:51; paper :96).
  final Color co;

  /// `--co-soft` (DS tokens/colors.css:51; paper :96).
  final Color coSoft;

  /// `--co-deep` (DS tokens/colors.css:51; paper :96).
  final Color coDeep;

  /// `--co-glow` (DS tokens/colors.css:51; paper :96).
  final Color coGlow;

  /// `--co-text` (DS tokens/colors.css:51; paper :96).
  final Color coText;

  /// `--co-ink` (DS tokens/colors.css:51; paper :96).
  final Color coInk;

  // ---- the accent role (moon under Multicolor) · DS tokens/colors.css:53-55 ----

  /// `--accent` (DS tokens/colors.css:55; paper :97).
  final Color accent;

  /// `--accent-ink` (DS tokens/colors.css:55; paper :97).
  final Color accentInk;

  /// `--accent-line` (DS tokens/colors.css:55; paper :97).
  final Color accentLine;

  /// `--accent-text` (DS tokens/colors.css:55; paper :97).
  final Color accentText;

  /// `--accent-soft` (DS tokens/colors.css:55; paper :97).
  final Color accentSoft;

  /// `--accent-soft-hi` (DS tokens/colors.css:55; paper :97).
  final Color accentSoftHi;

  /// `--accent-ring` (DS tokens/colors.css:55; paper :97).
  final Color accentRing;

  /// `--accent-select` (DS tokens/colors.css:55; paper :97).
  final Color accentSelect;

  // ---- live copies of the accent · DS tokens/colors.css:56-58 ----

  /// `--accent-live-line` (DS tokens/colors.css:57; paper :98).
  final Color accentLiveLine;

  /// `--accent-live-ring` (DS tokens/colors.css:57; paper :98).
  final Color accentLiveRing;

  /// `--accent-live-text` (DS tokens/colors.css:57; paper :98).
  final Color accentLiveText;

  // ---- moon as data · DS tokens/colors.css:59-63 ----

  /// `--status-m` (DS tokens/colors.css:60; paper :99).
  final Color statusM;

  /// `--status-m-bg` (DS tokens/colors.css:60; paper :99).
  final Color statusMBg;

  /// `--hunk` (DS tokens/colors.css:61; paper :99).
  final Color hunk;

  /// `--hunk-bg` (DS tokens/colors.css:61; paper :99).
  final Color hunkBg;

  /// `--remote` (DS tokens/colors.css:62; paper :99).
  final Color remote;

  // ---- project status · DS tokens/colors.css:64-66 ----

  /// `--proj-clean` (DS tokens/colors.css:65; paper :101).
  final Color projClean;

  /// `--proj-dirty` (DS tokens/colors.css:65; paper :101).
  final Color projDirty;

  /// `--proj-ahead` (DS tokens/colors.css:65; paper :101).
  final Color projAhead;

  /// `--proj-behind` (DS tokens/colors.css:65; paper :101).
  final Color projBehind;

  /// `--proj-diverged` (DS tokens/colors.css:65; paper :101).
  final Color projDiverged;

  /// `--proj-conflict` (DS tokens/colors.css:65; paper :101).
  final Color projConflict;

  /// `--proj-missing` (DS tokens/colors.css:65; paper :101).
  final Color projMissing;

  /// `--proj-syncing` (DS tokens/colors.css:65; paper :101).
  final Color projSyncing;

  /// `--proj-stale` (DS tokens/colors.css:65; paper :101).
  final Color projStale;

  // ---- semantic · DS tokens/colors.css:67-71 ----

  /// `--add` (DS tokens/colors.css:68; paper :103).
  final Color add;

  /// `--add-bg` (DS tokens/colors.css:68; paper :103).
  final Color addBg;

  /// `--rem` (DS tokens/colors.css:68; paper :103).
  final Color rem;

  /// `--rem-bg` (DS tokens/colors.css:68; paper :103).
  final Color remBg;

  /// `--add-bg-hi` (DS tokens/colors.css:69; paper :104).
  final Color addBgHi;

  /// `--add-edge` (DS tokens/colors.css:69; paper :104).
  final Color addEdge;

  /// `--add-ring` (DS tokens/colors.css:69; paper :104).
  final Color addRing;

  /// `--conflict` (DS tokens/colors.css:70; paper :106).
  final Color conflict;

  /// `--warn` (DS tokens/colors.css:70; paper :106).
  final Color warn;

  /// `--warn-bg` (DS tokens/colors.css:70; paper :106).
  final Color warnBg;

  // ---- readable aliases · DS tokens/colors.css:72-77 ----

  /// `--surface-window` = `--canvas` (DS tokens/colors.css:73; paper :107).
  ZsCanvasGradient get surfaceWindow => canvas;

  /// `--surface-card` = `--card-solid` (DS tokens/colors.css:73; paper :107).
  Color get surfaceCard => cardSolid;

  /// `--surface-card-hover` = `--card-solid-hi` (DS tokens/colors.css:73; paper :107).
  Color get surfaceCardHover => cardSolidHi;

  /// `--surface-glass` = `--fl-bg` (DS tokens/colors.css:73; paper :107).
  Color get surfaceGlass => flBg;

  /// `--surface-glass-strong` = `--fl-bg-strong` (DS tokens/colors.css:73; paper :107).
  Color get surfaceGlassStrong => flBgStrong;

  /// `--surface-popover` = `--fl-bg-solid` (DS tokens/colors.css:73; paper :107).
  Color get surfacePopover => flBgSolid;

  /// `--surface-menu` = `--fl-bg-solid` (DS tokens/colors.css:73; paper :107).
  Color get surfaceMenu => flBgSolid;

  /// `--surface-hover` = `--fl-hover` (DS tokens/colors.css:73; paper :107).
  Color get surfaceHover => flHover;

  /// `--surface-pressed` = `--fl-on` (DS tokens/colors.css:73; paper :107).
  Color get surfacePressed => flOn;

  /// `--surface-code` = `--code-bg` (DS tokens/colors.css:73; paper :107).
  Color get surfaceCode => codeBg;

  /// `--fg-1` = `--text` (DS tokens/colors.css:74; paper :108).
  Color get fg1 => text;

  /// `--fg-2` = `--text-muted` (DS tokens/colors.css:74; paper :108).
  Color get fg2 => textMuted;

  /// `--fg-3` = `--text-dim` (DS tokens/colors.css:74; paper :108).
  Color get fg3 => textDim;

  /// `--fg-4` = `--text-faint` (DS tokens/colors.css:74; paper :108).
  Color get fg4 => textFaint;

  /// `--line` = `--border` (DS tokens/colors.css:75; paper :109).
  Color get line => border;

  /// `--line-strong` = `--border-strong` (DS tokens/colors.css:75; paper :109).
  Color get lineStrong => borderStrong;

  /// `--line-glass` = `--fl-border` (DS tokens/colors.css:75; paper :109).
  Color get lineGlass => flBorder;

  /// `--primary` = `--primary-action` (DS tokens/colors.css:76; paper :110).
  Color get primary => primaryAction;

  /// `--working-copy` = `--co` (DS tokens/colors.css:76; paper :110).
  Color get workingCopy => co;

  /// `--selection` = `--accent` (DS tokens/colors.css:76; paper :110).
  Color get selection => accent;

  /// `--focus-ring` (DS tokens/colors.css:76; paper :110).
  final Color focusRing;

  // ---- fill ladder · DS tokens/states.css:8-16 ----

  /// `--fl-press` (DS tokens/states.css:9; paper :76).
  final Color flPress;

  /// `--fl-on-hover` (DS tokens/states.css:10; paper :76).
  final Color flOnHover;

  /// `--fill-on-hover` (DS tokens/states.css:12; paper :77).
  final Color fillOnHover;

  /// `--fill-on-press` (DS tokens/states.css:12; paper :77).
  final Color fillOnPress;

  /// `--add-ink` (DS tokens/states.css:13; paper :78).
  final Color addInk;

  /// `--field-bg` (DS tokens/states.css:15; paper :79).
  final Color fieldBg;

  /// `--seg-inset-bg` (DS tokens/states.css:15; paper :79).
  final Color segInsetBg;

  // ---- gold primary · DS tokens/states.css:28-33 ----

  /// `--primary-fill-a` (DS tokens/states.css:29; paper :80).
  final Color primaryFillA;

  /// `--primary-fill-b` (DS tokens/states.css:29; paper :80).
  final Color primaryFillB;

  /// `--primary-fill-a-hover` (DS tokens/states.css:30; paper :81).
  final Color primaryFillAHover;

  /// `--primary-fill-b-hover` (DS tokens/states.css:30; paper :81).
  final Color primaryFillBHover;

  /// `--primary-fill-a-press` (DS tokens/states.css:31; paper :82).
  final Color primaryFillAPress;

  /// `--primary-fill-b-press` (DS tokens/states.css:31; paper :82).
  final Color primaryFillBPress;

  /// `--primary-ring` (DS tokens/states.css:32; paper :83).
  final Color primaryRing;

  /// `--primary-ring-hover` (DS tokens/states.css:32; paper :83).
  final Color primaryRingHover;

  /// `--primary-icon` (DS tokens/states.css:32; paper :83).
  final Color primaryIcon;

  // ---- destructive · DS tokens/states.css:34-39 ----

  /// `--destructive-fill-a` (DS tokens/states.css:35; paper :84).
  final Color destructiveFillA;

  /// `--destructive-fill-b` (DS tokens/states.css:35; paper :84).
  final Color destructiveFillB;

  /// `--destructive-fill-a-hover` (DS tokens/states.css:36; paper :85).
  final Color destructiveFillAHover;

  /// `--destructive-fill-b-hover` (DS tokens/states.css:36; paper :85).
  final Color destructiveFillBHover;

  /// `--destructive-fill-a-press` (DS tokens/states.css:37; paper :86).
  final Color destructiveFillAPress;

  /// `--destructive-fill-b-press` (DS tokens/states.css:37; paper :86).
  final Color destructiveFillBPress;

  /// `--destructive-ring` (DS tokens/states.css:38; paper :87).
  final Color destructiveRing;

  /// `--destructive-ring-hover` (DS tokens/states.css:38; paper :87).
  final Color destructiveRingHover;

  // ---- danger · DS tokens/states.css:40-42 ----

  /// `--danger-hover` (DS tokens/states.css:41; paper :88).
  final Color dangerHover;

  /// `--danger-press` (DS tokens/states.css:41; paper :88).
  final Color dangerPress;

  // ---- tinted on-states · DS tokens/states.css:43-45 ----

  /// `--rem-bg-hover` (DS tokens/states.css:45; paper :89).
  final Color remBgHover;

  /// `--rem-bg-press` (DS tokens/states.css:45; paper :89).
  final Color remBgPress;

  // ---- error · DS tokens/states.css:46-48 ----

  /// `--error` (DS tokens/states.css:47; paper :90).
  final Color error;

  /// `--error-ring` (DS tokens/states.css:47; paper :90).
  final Color errorRing;

  // ---- thumbs · DS tokens/states.css:49-56 ----

  /// `--thumb` (DS tokens/states.css:50; paper :91).
  final Color thumb;

  /// `--thumb-edge` (DS tokens/states.css:50; paper :91).
  final Color thumbEdge;

  /// `--track` (DS tokens/states.css:53; paper :94).
  final Color track;

  /// `--track-hover` (DS tokens/states.css:53; paper :94).
  final Color trackHover;

  /// `--track-edge` (DS tokens/states.css:53).
  final Color trackEdge;

  /// `--track-edge-hover` (DS tokens/states.css:53).
  final Color trackEdgeHover;

  /// `--tick` (DS tokens/states.css:53; paper :94).
  final Color tick;

  /// `--progress-track` (DS tokens/states.css:55; paper :94).
  final Color progressTrack;

  // ---- overlay scrollbar · DS tokens/states.css:57-60 ----

  /// `--scroll-thumb` (DS tokens/states.css:58; paper :95).
  final Color scrollThumb;

  /// `--scroll-thumb-hover` (DS tokens/states.css:58; paper :95).
  final Color scrollThumbHover;

  /// `--scroll-thumb-drag` (DS tokens/states.css:58; paper :95).
  final Color scrollThumbDrag;

  /// `--scroll-track` (DS tokens/states.css:58; paper :95).
  final Color scrollTrack;

  // ---- tooltip · DS tokens/states.css:61-64 ----

  /// `--tooltip-bg` (DS tokens/states.css:62; paper :96).
  final Color tooltipBg;

  /// `--tooltip-border` (DS tokens/states.css:62; paper :96).
  final Color tooltipBorder;

  // ---- pending · DS tokens/states.css:65-67 ----

  /// `--skeleton` (DS tokens/states.css:66; paper :98).
  final Color skeleton;

  /// `--skeleton-hi` (DS tokens/states.css:66; paper :98).
  final Color skeletonHi;

  // ---- text selection · DS tokens/states.css:68-74 ----

  /// `--selection-text` = `--text` (DS tokens/states.css:71).
  Color get selectionText => text;

  /// `--selection-text-alt` (DS tokens/states.css:72; paper :99).
  final Color selectionTextAlt;

  /// `--select-inactive` (DS tokens/states.css:73; paper :99).
  final Color selectInactive;

  /// The 11 accent tokens this set carries (DS tokens/accents.css:13-24).
  ZsAccentTokens get accentTokens => ZsAccentTokens(
    accent: accent,
    accentInk: accentInk,
    accentLine: accentLine,
    accentText: accentText,
    accentSoft: accentSoft,
    accentSoftHi: accentSoftHi,
    accentRing: accentRing,
    accentSelect: accentSelect,
    accentLiveLine: accentLiveLine,
    accentLiveRing: accentLiveRing,
    accentLiveText: accentLiveText,
  );

  @override
  ZsColors copyWith({
    Color? night0,
    Color? night1,
    Color? night2,
    Color? night3,
    Color? night4,
    Color? night5,
    Color? nightIcon,
    Color? nightLift,
    Color? paper0,
    Color? paper1,
    Color? paper2,
    Color? paper3,
    Color? paper4,
    Color? paperInk,
    Color? umber,
    Color? gold50,
    Color? gold200,
    Color? gold400,
    Color? gold600,
    Color? goldInk,
    Color? saffron,
    Color? saffronPaper,
    Color? moon,
    Color? moonPaper,
    Color? green400,
    Color? green700,
    Color? red400,
    Color? red600,
    Color? amber400,
    Color? amberPaper,
    Color? tlClose,
    Color? tlMin,
    Color? tlZoom,
    Color? tlIdle,
    Color? tlRing,
    ZsCanvasGradient? canvas,
    Color? canvasBase,
    Color? gold,
    Color? cardSolid,
    Color? cardSolidHi,
    Color? hatch,
    Color? hatchMark,
    Color? bgCard,
    Color? bgCard2,
    Color? border,
    Color? borderStrong,
    Color? codeBg,
    Color? scrim,
    Color? flBg,
    Color? flBgStrong,
    Color? flBgSolid,
    Color? flBorder,
    ZsLinearGradient? flSheen,
    Color? flHover,
    Color? flOn,
    Color? primaryAction,
    Color? atChrome,
    Color? atChromeEdge,
    Color? text,
    Color? textMuted,
    Color? textDim,
    Color? textFaint,
    Color? edge,
    Color? edgeHov,
    Color? co,
    Color? coSoft,
    Color? coDeep,
    Color? coGlow,
    Color? coText,
    Color? coInk,
    Color? accent,
    Color? accentInk,
    Color? accentLine,
    Color? accentText,
    Color? accentSoft,
    Color? accentSoftHi,
    Color? accentRing,
    Color? accentSelect,
    Color? accentLiveLine,
    Color? accentLiveRing,
    Color? accentLiveText,
    Color? statusM,
    Color? statusMBg,
    Color? hunk,
    Color? hunkBg,
    Color? remote,
    Color? projClean,
    Color? projDirty,
    Color? projAhead,
    Color? projBehind,
    Color? projDiverged,
    Color? projConflict,
    Color? projMissing,
    Color? projSyncing,
    Color? projStale,
    Color? add,
    Color? addBg,
    Color? rem,
    Color? remBg,
    Color? addBgHi,
    Color? addEdge,
    Color? addRing,
    Color? conflict,
    Color? warn,
    Color? warnBg,
    Color? focusRing,
    Color? flPress,
    Color? flOnHover,
    Color? fillOnHover,
    Color? fillOnPress,
    Color? addInk,
    Color? fieldBg,
    Color? segInsetBg,
    Color? primaryFillA,
    Color? primaryFillB,
    Color? primaryFillAHover,
    Color? primaryFillBHover,
    Color? primaryFillAPress,
    Color? primaryFillBPress,
    Color? primaryRing,
    Color? primaryRingHover,
    Color? primaryIcon,
    Color? destructiveFillA,
    Color? destructiveFillB,
    Color? destructiveFillAHover,
    Color? destructiveFillBHover,
    Color? destructiveFillAPress,
    Color? destructiveFillBPress,
    Color? destructiveRing,
    Color? destructiveRingHover,
    Color? dangerHover,
    Color? dangerPress,
    Color? remBgHover,
    Color? remBgPress,
    Color? error,
    Color? errorRing,
    Color? thumb,
    Color? thumbEdge,
    Color? track,
    Color? trackHover,
    Color? trackEdge,
    Color? trackEdgeHover,
    Color? tick,
    Color? progressTrack,
    Color? scrollThumb,
    Color? scrollThumbHover,
    Color? scrollThumbDrag,
    Color? scrollTrack,
    Color? tooltipBg,
    Color? tooltipBorder,
    Color? skeleton,
    Color? skeletonHi,
    Color? selectionTextAlt,
    Color? selectInactive,
  }) => ZsColors(
    night0: night0 ?? this.night0,
    night1: night1 ?? this.night1,
    night2: night2 ?? this.night2,
    night3: night3 ?? this.night3,
    night4: night4 ?? this.night4,
    night5: night5 ?? this.night5,
    nightIcon: nightIcon ?? this.nightIcon,
    nightLift: nightLift ?? this.nightLift,
    paper0: paper0 ?? this.paper0,
    paper1: paper1 ?? this.paper1,
    paper2: paper2 ?? this.paper2,
    paper3: paper3 ?? this.paper3,
    paper4: paper4 ?? this.paper4,
    paperInk: paperInk ?? this.paperInk,
    umber: umber ?? this.umber,
    gold50: gold50 ?? this.gold50,
    gold200: gold200 ?? this.gold200,
    gold400: gold400 ?? this.gold400,
    gold600: gold600 ?? this.gold600,
    goldInk: goldInk ?? this.goldInk,
    saffron: saffron ?? this.saffron,
    saffronPaper: saffronPaper ?? this.saffronPaper,
    moon: moon ?? this.moon,
    moonPaper: moonPaper ?? this.moonPaper,
    green400: green400 ?? this.green400,
    green700: green700 ?? this.green700,
    red400: red400 ?? this.red400,
    red600: red600 ?? this.red600,
    amber400: amber400 ?? this.amber400,
    amberPaper: amberPaper ?? this.amberPaper,
    tlClose: tlClose ?? this.tlClose,
    tlMin: tlMin ?? this.tlMin,
    tlZoom: tlZoom ?? this.tlZoom,
    tlIdle: tlIdle ?? this.tlIdle,
    tlRing: tlRing ?? this.tlRing,
    canvas: canvas ?? this.canvas,
    canvasBase: canvasBase ?? this.canvasBase,
    gold: gold ?? this.gold,
    cardSolid: cardSolid ?? this.cardSolid,
    cardSolidHi: cardSolidHi ?? this.cardSolidHi,
    hatch: hatch ?? this.hatch,
    hatchMark: hatchMark ?? this.hatchMark,
    bgCard: bgCard ?? this.bgCard,
    bgCard2: bgCard2 ?? this.bgCard2,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    codeBg: codeBg ?? this.codeBg,
    scrim: scrim ?? this.scrim,
    flBg: flBg ?? this.flBg,
    flBgStrong: flBgStrong ?? this.flBgStrong,
    flBgSolid: flBgSolid ?? this.flBgSolid,
    flBorder: flBorder ?? this.flBorder,
    flSheen: flSheen ?? this.flSheen,
    flHover: flHover ?? this.flHover,
    flOn: flOn ?? this.flOn,
    primaryAction: primaryAction ?? this.primaryAction,
    atChrome: atChrome ?? this.atChrome,
    atChromeEdge: atChromeEdge ?? this.atChromeEdge,
    text: text ?? this.text,
    textMuted: textMuted ?? this.textMuted,
    textDim: textDim ?? this.textDim,
    textFaint: textFaint ?? this.textFaint,
    edge: edge ?? this.edge,
    edgeHov: edgeHov ?? this.edgeHov,
    co: co ?? this.co,
    coSoft: coSoft ?? this.coSoft,
    coDeep: coDeep ?? this.coDeep,
    coGlow: coGlow ?? this.coGlow,
    coText: coText ?? this.coText,
    coInk: coInk ?? this.coInk,
    accent: accent ?? this.accent,
    accentInk: accentInk ?? this.accentInk,
    accentLine: accentLine ?? this.accentLine,
    accentText: accentText ?? this.accentText,
    accentSoft: accentSoft ?? this.accentSoft,
    accentSoftHi: accentSoftHi ?? this.accentSoftHi,
    accentRing: accentRing ?? this.accentRing,
    accentSelect: accentSelect ?? this.accentSelect,
    accentLiveLine: accentLiveLine ?? this.accentLiveLine,
    accentLiveRing: accentLiveRing ?? this.accentLiveRing,
    accentLiveText: accentLiveText ?? this.accentLiveText,
    statusM: statusM ?? this.statusM,
    statusMBg: statusMBg ?? this.statusMBg,
    hunk: hunk ?? this.hunk,
    hunkBg: hunkBg ?? this.hunkBg,
    remote: remote ?? this.remote,
    projClean: projClean ?? this.projClean,
    projDirty: projDirty ?? this.projDirty,
    projAhead: projAhead ?? this.projAhead,
    projBehind: projBehind ?? this.projBehind,
    projDiverged: projDiverged ?? this.projDiverged,
    projConflict: projConflict ?? this.projConflict,
    projMissing: projMissing ?? this.projMissing,
    projSyncing: projSyncing ?? this.projSyncing,
    projStale: projStale ?? this.projStale,
    add: add ?? this.add,
    addBg: addBg ?? this.addBg,
    rem: rem ?? this.rem,
    remBg: remBg ?? this.remBg,
    addBgHi: addBgHi ?? this.addBgHi,
    addEdge: addEdge ?? this.addEdge,
    addRing: addRing ?? this.addRing,
    conflict: conflict ?? this.conflict,
    warn: warn ?? this.warn,
    warnBg: warnBg ?? this.warnBg,
    focusRing: focusRing ?? this.focusRing,
    flPress: flPress ?? this.flPress,
    flOnHover: flOnHover ?? this.flOnHover,
    fillOnHover: fillOnHover ?? this.fillOnHover,
    fillOnPress: fillOnPress ?? this.fillOnPress,
    addInk: addInk ?? this.addInk,
    fieldBg: fieldBg ?? this.fieldBg,
    segInsetBg: segInsetBg ?? this.segInsetBg,
    primaryFillA: primaryFillA ?? this.primaryFillA,
    primaryFillB: primaryFillB ?? this.primaryFillB,
    primaryFillAHover: primaryFillAHover ?? this.primaryFillAHover,
    primaryFillBHover: primaryFillBHover ?? this.primaryFillBHover,
    primaryFillAPress: primaryFillAPress ?? this.primaryFillAPress,
    primaryFillBPress: primaryFillBPress ?? this.primaryFillBPress,
    primaryRing: primaryRing ?? this.primaryRing,
    primaryRingHover: primaryRingHover ?? this.primaryRingHover,
    primaryIcon: primaryIcon ?? this.primaryIcon,
    destructiveFillA: destructiveFillA ?? this.destructiveFillA,
    destructiveFillB: destructiveFillB ?? this.destructiveFillB,
    destructiveFillAHover: destructiveFillAHover ?? this.destructiveFillAHover,
    destructiveFillBHover: destructiveFillBHover ?? this.destructiveFillBHover,
    destructiveFillAPress: destructiveFillAPress ?? this.destructiveFillAPress,
    destructiveFillBPress: destructiveFillBPress ?? this.destructiveFillBPress,
    destructiveRing: destructiveRing ?? this.destructiveRing,
    destructiveRingHover: destructiveRingHover ?? this.destructiveRingHover,
    dangerHover: dangerHover ?? this.dangerHover,
    dangerPress: dangerPress ?? this.dangerPress,
    remBgHover: remBgHover ?? this.remBgHover,
    remBgPress: remBgPress ?? this.remBgPress,
    error: error ?? this.error,
    errorRing: errorRing ?? this.errorRing,
    thumb: thumb ?? this.thumb,
    thumbEdge: thumbEdge ?? this.thumbEdge,
    track: track ?? this.track,
    trackHover: trackHover ?? this.trackHover,
    trackEdge: trackEdge ?? this.trackEdge,
    trackEdgeHover: trackEdgeHover ?? this.trackEdgeHover,
    tick: tick ?? this.tick,
    progressTrack: progressTrack ?? this.progressTrack,
    scrollThumb: scrollThumb ?? this.scrollThumb,
    scrollThumbHover: scrollThumbHover ?? this.scrollThumbHover,
    scrollThumbDrag: scrollThumbDrag ?? this.scrollThumbDrag,
    scrollTrack: scrollTrack ?? this.scrollTrack,
    tooltipBg: tooltipBg ?? this.tooltipBg,
    tooltipBorder: tooltipBorder ?? this.tooltipBorder,
    skeleton: skeleton ?? this.skeleton,
    skeletonHi: skeletonHi ?? this.skeletonHi,
    selectionTextAlt: selectionTextAlt ?? this.selectionTextAlt,
    selectInactive: selectInactive ?? this.selectInactive,
  );

  /// Field-wise; also across accent families, so a switch is smooth.
  @override
  ZsColors lerp(ZsColors? other, double t) {
    if (other == null) {
      return this;
    }
    return ZsColors(
      night0: Color.lerp(night0, other.night0, t)!,
      night1: Color.lerp(night1, other.night1, t)!,
      night2: Color.lerp(night2, other.night2, t)!,
      night3: Color.lerp(night3, other.night3, t)!,
      night4: Color.lerp(night4, other.night4, t)!,
      night5: Color.lerp(night5, other.night5, t)!,
      nightIcon: Color.lerp(nightIcon, other.nightIcon, t)!,
      nightLift: Color.lerp(nightLift, other.nightLift, t)!,
      paper0: Color.lerp(paper0, other.paper0, t)!,
      paper1: Color.lerp(paper1, other.paper1, t)!,
      paper2: Color.lerp(paper2, other.paper2, t)!,
      paper3: Color.lerp(paper3, other.paper3, t)!,
      paper4: Color.lerp(paper4, other.paper4, t)!,
      paperInk: Color.lerp(paperInk, other.paperInk, t)!,
      umber: Color.lerp(umber, other.umber, t)!,
      gold50: Color.lerp(gold50, other.gold50, t)!,
      gold200: Color.lerp(gold200, other.gold200, t)!,
      gold400: Color.lerp(gold400, other.gold400, t)!,
      gold600: Color.lerp(gold600, other.gold600, t)!,
      goldInk: Color.lerp(goldInk, other.goldInk, t)!,
      saffron: Color.lerp(saffron, other.saffron, t)!,
      saffronPaper: Color.lerp(saffronPaper, other.saffronPaper, t)!,
      moon: Color.lerp(moon, other.moon, t)!,
      moonPaper: Color.lerp(moonPaper, other.moonPaper, t)!,
      green400: Color.lerp(green400, other.green400, t)!,
      green700: Color.lerp(green700, other.green700, t)!,
      red400: Color.lerp(red400, other.red400, t)!,
      red600: Color.lerp(red600, other.red600, t)!,
      amber400: Color.lerp(amber400, other.amber400, t)!,
      amberPaper: Color.lerp(amberPaper, other.amberPaper, t)!,
      tlClose: Color.lerp(tlClose, other.tlClose, t)!,
      tlMin: Color.lerp(tlMin, other.tlMin, t)!,
      tlZoom: Color.lerp(tlZoom, other.tlZoom, t)!,
      tlIdle: Color.lerp(tlIdle, other.tlIdle, t)!,
      tlRing: Color.lerp(tlRing, other.tlRing, t)!,
      canvas: ZsCanvasGradient.lerp(canvas, other.canvas, t),
      canvasBase: Color.lerp(canvasBase, other.canvasBase, t)!,
      gold: Color.lerp(gold, other.gold, t)!,
      cardSolid: Color.lerp(cardSolid, other.cardSolid, t)!,
      cardSolidHi: Color.lerp(cardSolidHi, other.cardSolidHi, t)!,
      hatch: Color.lerp(hatch, other.hatch, t)!,
      hatchMark: Color.lerp(hatchMark, other.hatchMark, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      bgCard2: Color.lerp(bgCard2, other.bgCard2, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      flBg: Color.lerp(flBg, other.flBg, t)!,
      flBgStrong: Color.lerp(flBgStrong, other.flBgStrong, t)!,
      flBgSolid: Color.lerp(flBgSolid, other.flBgSolid, t)!,
      flBorder: Color.lerp(flBorder, other.flBorder, t)!,
      flSheen: ZsLinearGradient.lerp(flSheen, other.flSheen, t),
      flHover: Color.lerp(flHover, other.flHover, t)!,
      flOn: Color.lerp(flOn, other.flOn, t)!,
      primaryAction: Color.lerp(primaryAction, other.primaryAction, t)!,
      atChrome: Color.lerp(atChrome, other.atChrome, t)!,
      atChromeEdge: Color.lerp(atChromeEdge, other.atChromeEdge, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      edge: Color.lerp(edge, other.edge, t)!,
      edgeHov: Color.lerp(edgeHov, other.edgeHov, t)!,
      co: Color.lerp(co, other.co, t)!,
      coSoft: Color.lerp(coSoft, other.coSoft, t)!,
      coDeep: Color.lerp(coDeep, other.coDeep, t)!,
      coGlow: Color.lerp(coGlow, other.coGlow, t)!,
      coText: Color.lerp(coText, other.coText, t)!,
      coInk: Color.lerp(coInk, other.coInk, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      accentLine: Color.lerp(accentLine, other.accentLine, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentSoftHi: Color.lerp(accentSoftHi, other.accentSoftHi, t)!,
      accentRing: Color.lerp(accentRing, other.accentRing, t)!,
      accentSelect: Color.lerp(accentSelect, other.accentSelect, t)!,
      accentLiveLine: Color.lerp(accentLiveLine, other.accentLiveLine, t)!,
      accentLiveRing: Color.lerp(accentLiveRing, other.accentLiveRing, t)!,
      accentLiveText: Color.lerp(accentLiveText, other.accentLiveText, t)!,
      statusM: Color.lerp(statusM, other.statusM, t)!,
      statusMBg: Color.lerp(statusMBg, other.statusMBg, t)!,
      hunk: Color.lerp(hunk, other.hunk, t)!,
      hunkBg: Color.lerp(hunkBg, other.hunkBg, t)!,
      remote: Color.lerp(remote, other.remote, t)!,
      projClean: Color.lerp(projClean, other.projClean, t)!,
      projDirty: Color.lerp(projDirty, other.projDirty, t)!,
      projAhead: Color.lerp(projAhead, other.projAhead, t)!,
      projBehind: Color.lerp(projBehind, other.projBehind, t)!,
      projDiverged: Color.lerp(projDiverged, other.projDiverged, t)!,
      projConflict: Color.lerp(projConflict, other.projConflict, t)!,
      projMissing: Color.lerp(projMissing, other.projMissing, t)!,
      projSyncing: Color.lerp(projSyncing, other.projSyncing, t)!,
      projStale: Color.lerp(projStale, other.projStale, t)!,
      add: Color.lerp(add, other.add, t)!,
      addBg: Color.lerp(addBg, other.addBg, t)!,
      rem: Color.lerp(rem, other.rem, t)!,
      remBg: Color.lerp(remBg, other.remBg, t)!,
      addBgHi: Color.lerp(addBgHi, other.addBgHi, t)!,
      addEdge: Color.lerp(addEdge, other.addEdge, t)!,
      addRing: Color.lerp(addRing, other.addRing, t)!,
      conflict: Color.lerp(conflict, other.conflict, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      warnBg: Color.lerp(warnBg, other.warnBg, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      flPress: Color.lerp(flPress, other.flPress, t)!,
      flOnHover: Color.lerp(flOnHover, other.flOnHover, t)!,
      fillOnHover: Color.lerp(fillOnHover, other.fillOnHover, t)!,
      fillOnPress: Color.lerp(fillOnPress, other.fillOnPress, t)!,
      addInk: Color.lerp(addInk, other.addInk, t)!,
      fieldBg: Color.lerp(fieldBg, other.fieldBg, t)!,
      segInsetBg: Color.lerp(segInsetBg, other.segInsetBg, t)!,
      primaryFillA: Color.lerp(primaryFillA, other.primaryFillA, t)!,
      primaryFillB: Color.lerp(primaryFillB, other.primaryFillB, t)!,
      primaryFillAHover: Color.lerp(primaryFillAHover, other.primaryFillAHover, t)!,
      primaryFillBHover: Color.lerp(primaryFillBHover, other.primaryFillBHover, t)!,
      primaryFillAPress: Color.lerp(primaryFillAPress, other.primaryFillAPress, t)!,
      primaryFillBPress: Color.lerp(primaryFillBPress, other.primaryFillBPress, t)!,
      primaryRing: Color.lerp(primaryRing, other.primaryRing, t)!,
      primaryRingHover: Color.lerp(primaryRingHover, other.primaryRingHover, t)!,
      primaryIcon: Color.lerp(primaryIcon, other.primaryIcon, t)!,
      destructiveFillA: Color.lerp(destructiveFillA, other.destructiveFillA, t)!,
      destructiveFillB: Color.lerp(destructiveFillB, other.destructiveFillB, t)!,
      destructiveFillAHover: Color.lerp(destructiveFillAHover, other.destructiveFillAHover, t)!,
      destructiveFillBHover: Color.lerp(destructiveFillBHover, other.destructiveFillBHover, t)!,
      destructiveFillAPress: Color.lerp(destructiveFillAPress, other.destructiveFillAPress, t)!,
      destructiveFillBPress: Color.lerp(destructiveFillBPress, other.destructiveFillBPress, t)!,
      destructiveRing: Color.lerp(destructiveRing, other.destructiveRing, t)!,
      destructiveRingHover: Color.lerp(destructiveRingHover, other.destructiveRingHover, t)!,
      dangerHover: Color.lerp(dangerHover, other.dangerHover, t)!,
      dangerPress: Color.lerp(dangerPress, other.dangerPress, t)!,
      remBgHover: Color.lerp(remBgHover, other.remBgHover, t)!,
      remBgPress: Color.lerp(remBgPress, other.remBgPress, t)!,
      error: Color.lerp(error, other.error, t)!,
      errorRing: Color.lerp(errorRing, other.errorRing, t)!,
      thumb: Color.lerp(thumb, other.thumb, t)!,
      thumbEdge: Color.lerp(thumbEdge, other.thumbEdge, t)!,
      track: Color.lerp(track, other.track, t)!,
      trackHover: Color.lerp(trackHover, other.trackHover, t)!,
      trackEdge: Color.lerp(trackEdge, other.trackEdge, t)!,
      trackEdgeHover: Color.lerp(trackEdgeHover, other.trackEdgeHover, t)!,
      tick: Color.lerp(tick, other.tick, t)!,
      progressTrack: Color.lerp(progressTrack, other.progressTrack, t)!,
      scrollThumb: Color.lerp(scrollThumb, other.scrollThumb, t)!,
      scrollThumbHover: Color.lerp(scrollThumbHover, other.scrollThumbHover, t)!,
      scrollThumbDrag: Color.lerp(scrollThumbDrag, other.scrollThumbDrag, t)!,
      scrollTrack: Color.lerp(scrollTrack, other.scrollTrack, t)!,
      tooltipBg: Color.lerp(tooltipBg, other.tooltipBg, t)!,
      tooltipBorder: Color.lerp(tooltipBorder, other.tooltipBorder, t)!,
      skeleton: Color.lerp(skeleton, other.skeleton, t)!,
      skeletonHi: Color.lerp(skeletonHi, other.skeletonHi, t)!,
      selectionTextAlt: Color.lerp(selectionTextAlt, other.selectionTextAlt, t)!,
      selectInactive: Color.lerp(selectInactive, other.selectInactive, t)!,
    );
  }

  /// Every token as `'--name' → value`, aliases and `--accent-native(-dark)` included; for the DS parity test.
  Map<String, Object> toCss() => <String, Object>{
    '--night-0': night0,
    '--night-1': night1,
    '--night-2': night2,
    '--night-3': night3,
    '--night-4': night4,
    '--night-5': night5,
    '--night-icon': nightIcon,
    '--night-lift': nightLift,
    '--paper-0': paper0,
    '--paper-1': paper1,
    '--paper-2': paper2,
    '--paper-3': paper3,
    '--paper-4': paper4,
    '--paper-ink': paperInk,
    '--umber': umber,
    '--gold-50': gold50,
    '--gold-200': gold200,
    '--gold-400': gold400,
    '--gold-600': gold600,
    '--gold-ink': goldInk,
    '--saffron': saffron,
    '--saffron-paper': saffronPaper,
    '--moon': moon,
    '--moon-paper': moonPaper,
    '--green-400': green400,
    '--green-700': green700,
    '--red-400': red400,
    '--red-600': red600,
    '--amber-400': amber400,
    '--amber-paper': amberPaper,
    '--tl-close': tlClose,
    '--tl-min': tlMin,
    '--tl-zoom': tlZoom,
    '--tl-idle': tlIdle,
    '--tl-ring': tlRing,
    '--canvas': canvas,
    '--canvas-base': canvasBase,
    '--gold': gold,
    '--card-solid': cardSolid,
    '--card-solid-hi': cardSolidHi,
    '--hatch': hatch,
    '--hatch-mark': hatchMark,
    '--bg-card': bgCard,
    '--bg-card-2': bgCard2,
    '--border': border,
    '--border-strong': borderStrong,
    '--code-bg': codeBg,
    '--scrim': scrim,
    '--fl-bg': flBg,
    '--fl-bg-strong': flBgStrong,
    '--fl-bg-solid': flBgSolid,
    '--fl-border': flBorder,
    '--fl-sheen': flSheen,
    '--fl-hover': flHover,
    '--fl-on': flOn,
    '--primary-action': primaryAction,
    '--at-chrome': atChrome,
    '--at-chrome-edge': atChromeEdge,
    '--text': text,
    '--text-muted': textMuted,
    '--text-dim': textDim,
    '--text-faint': textFaint,
    '--edge': edge,
    '--edge-hov': edgeHov,
    '--co': co,
    '--co-soft': coSoft,
    '--co-deep': coDeep,
    '--co-glow': coGlow,
    '--co-text': coText,
    '--co-ink': coInk,
    '--accent': accent,
    '--accent-ink': accentInk,
    '--accent-line': accentLine,
    '--accent-text': accentText,
    '--accent-soft': accentSoft,
    '--accent-soft-hi': accentSoftHi,
    '--accent-ring': accentRing,
    '--accent-select': accentSelect,
    '--accent-live-line': accentLiveLine,
    '--accent-live-ring': accentLiveRing,
    '--accent-live-text': accentLiveText,
    '--status-m': statusM,
    '--status-m-bg': statusMBg,
    '--hunk': hunk,
    '--hunk-bg': hunkBg,
    '--remote': remote,
    '--proj-clean': projClean,
    '--proj-dirty': projDirty,
    '--proj-ahead': projAhead,
    '--proj-behind': projBehind,
    '--proj-diverged': projDiverged,
    '--proj-conflict': projConflict,
    '--proj-missing': projMissing,
    '--proj-syncing': projSyncing,
    '--proj-stale': projStale,
    '--add': add,
    '--add-bg': addBg,
    '--rem': rem,
    '--rem-bg': remBg,
    '--add-bg-hi': addBgHi,
    '--add-edge': addEdge,
    '--add-ring': addRing,
    '--conflict': conflict,
    '--warn': warn,
    '--warn-bg': warnBg,
    '--surface-window': surfaceWindow,
    '--surface-card': surfaceCard,
    '--surface-card-hover': surfaceCardHover,
    '--surface-glass': surfaceGlass,
    '--surface-glass-strong': surfaceGlassStrong,
    '--surface-popover': surfacePopover,
    '--surface-menu': surfaceMenu,
    '--surface-hover': surfaceHover,
    '--surface-pressed': surfacePressed,
    '--surface-code': surfaceCode,
    '--fg-1': fg1,
    '--fg-2': fg2,
    '--fg-3': fg3,
    '--fg-4': fg4,
    '--line': line,
    '--line-strong': lineStrong,
    '--line-glass': lineGlass,
    '--primary': primary,
    '--working-copy': workingCopy,
    '--selection': selection,
    '--focus-ring': focusRing,
    '--accent-native': ZsAccents.native,
    '--accent-native-dark': ZsAccents.nativeDark,
    '--fl-press': flPress,
    '--fl-on-hover': flOnHover,
    '--fill-on-hover': fillOnHover,
    '--fill-on-press': fillOnPress,
    '--add-ink': addInk,
    '--field-bg': fieldBg,
    '--seg-inset-bg': segInsetBg,
    '--primary-fill-a': primaryFillA,
    '--primary-fill-b': primaryFillB,
    '--primary-fill-a-hover': primaryFillAHover,
    '--primary-fill-b-hover': primaryFillBHover,
    '--primary-fill-a-press': primaryFillAPress,
    '--primary-fill-b-press': primaryFillBPress,
    '--primary-ring': primaryRing,
    '--primary-ring-hover': primaryRingHover,
    '--primary-icon': primaryIcon,
    '--destructive-fill-a': destructiveFillA,
    '--destructive-fill-b': destructiveFillB,
    '--destructive-fill-a-hover': destructiveFillAHover,
    '--destructive-fill-b-hover': destructiveFillBHover,
    '--destructive-fill-a-press': destructiveFillAPress,
    '--destructive-fill-b-press': destructiveFillBPress,
    '--destructive-ring': destructiveRing,
    '--destructive-ring-hover': destructiveRingHover,
    '--danger-hover': dangerHover,
    '--danger-press': dangerPress,
    '--rem-bg-hover': remBgHover,
    '--rem-bg-press': remBgPress,
    '--error': error,
    '--error-ring': errorRing,
    '--thumb': thumb,
    '--thumb-edge': thumbEdge,
    '--track': track,
    '--track-hover': trackHover,
    '--track-edge': trackEdge,
    '--track-edge-hover': trackEdgeHover,
    '--tick': tick,
    '--progress-track': progressTrack,
    '--scroll-thumb': scrollThumb,
    '--scroll-thumb-hover': scrollThumbHover,
    '--scroll-thumb-drag': scrollThumbDrag,
    '--scroll-track': scrollTrack,
    '--tooltip-bg': tooltipBg,
    '--tooltip-border': tooltipBorder,
    '--skeleton': skeleton,
    '--skeleton-hi': skeletonHi,
    '--selection-text': selectionText,
    '--selection-text-alt': selectionTextAlt,
    '--select-inactive': selectInactive,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsColors &&
          other.night0 == night0 &&
          other.night1 == night1 &&
          other.night2 == night2 &&
          other.night3 == night3 &&
          other.night4 == night4 &&
          other.night5 == night5 &&
          other.nightIcon == nightIcon &&
          other.nightLift == nightLift &&
          other.paper0 == paper0 &&
          other.paper1 == paper1 &&
          other.paper2 == paper2 &&
          other.paper3 == paper3 &&
          other.paper4 == paper4 &&
          other.paperInk == paperInk &&
          other.umber == umber &&
          other.gold50 == gold50 &&
          other.gold200 == gold200 &&
          other.gold400 == gold400 &&
          other.gold600 == gold600 &&
          other.goldInk == goldInk &&
          other.saffron == saffron &&
          other.saffronPaper == saffronPaper &&
          other.moon == moon &&
          other.moonPaper == moonPaper &&
          other.green400 == green400 &&
          other.green700 == green700 &&
          other.red400 == red400 &&
          other.red600 == red600 &&
          other.amber400 == amber400 &&
          other.amberPaper == amberPaper &&
          other.tlClose == tlClose &&
          other.tlMin == tlMin &&
          other.tlZoom == tlZoom &&
          other.tlIdle == tlIdle &&
          other.tlRing == tlRing &&
          other.canvas == canvas &&
          other.canvasBase == canvasBase &&
          other.gold == gold &&
          other.cardSolid == cardSolid &&
          other.cardSolidHi == cardSolidHi &&
          other.hatch == hatch &&
          other.hatchMark == hatchMark &&
          other.bgCard == bgCard &&
          other.bgCard2 == bgCard2 &&
          other.border == border &&
          other.borderStrong == borderStrong &&
          other.codeBg == codeBg &&
          other.scrim == scrim &&
          other.flBg == flBg &&
          other.flBgStrong == flBgStrong &&
          other.flBgSolid == flBgSolid &&
          other.flBorder == flBorder &&
          other.flSheen == flSheen &&
          other.flHover == flHover &&
          other.flOn == flOn &&
          other.primaryAction == primaryAction &&
          other.atChrome == atChrome &&
          other.atChromeEdge == atChromeEdge &&
          other.text == text &&
          other.textMuted == textMuted &&
          other.textDim == textDim &&
          other.textFaint == textFaint &&
          other.edge == edge &&
          other.edgeHov == edgeHov &&
          other.co == co &&
          other.coSoft == coSoft &&
          other.coDeep == coDeep &&
          other.coGlow == coGlow &&
          other.coText == coText &&
          other.coInk == coInk &&
          other.accent == accent &&
          other.accentInk == accentInk &&
          other.accentLine == accentLine &&
          other.accentText == accentText &&
          other.accentSoft == accentSoft &&
          other.accentSoftHi == accentSoftHi &&
          other.accentRing == accentRing &&
          other.accentSelect == accentSelect &&
          other.accentLiveLine == accentLiveLine &&
          other.accentLiveRing == accentLiveRing &&
          other.accentLiveText == accentLiveText &&
          other.statusM == statusM &&
          other.statusMBg == statusMBg &&
          other.hunk == hunk &&
          other.hunkBg == hunkBg &&
          other.remote == remote &&
          other.projClean == projClean &&
          other.projDirty == projDirty &&
          other.projAhead == projAhead &&
          other.projBehind == projBehind &&
          other.projDiverged == projDiverged &&
          other.projConflict == projConflict &&
          other.projMissing == projMissing &&
          other.projSyncing == projSyncing &&
          other.projStale == projStale &&
          other.add == add &&
          other.addBg == addBg &&
          other.rem == rem &&
          other.remBg == remBg &&
          other.addBgHi == addBgHi &&
          other.addEdge == addEdge &&
          other.addRing == addRing &&
          other.conflict == conflict &&
          other.warn == warn &&
          other.warnBg == warnBg &&
          other.focusRing == focusRing &&
          other.flPress == flPress &&
          other.flOnHover == flOnHover &&
          other.fillOnHover == fillOnHover &&
          other.fillOnPress == fillOnPress &&
          other.addInk == addInk &&
          other.fieldBg == fieldBg &&
          other.segInsetBg == segInsetBg &&
          other.primaryFillA == primaryFillA &&
          other.primaryFillB == primaryFillB &&
          other.primaryFillAHover == primaryFillAHover &&
          other.primaryFillBHover == primaryFillBHover &&
          other.primaryFillAPress == primaryFillAPress &&
          other.primaryFillBPress == primaryFillBPress &&
          other.primaryRing == primaryRing &&
          other.primaryRingHover == primaryRingHover &&
          other.primaryIcon == primaryIcon &&
          other.destructiveFillA == destructiveFillA &&
          other.destructiveFillB == destructiveFillB &&
          other.destructiveFillAHover == destructiveFillAHover &&
          other.destructiveFillBHover == destructiveFillBHover &&
          other.destructiveFillAPress == destructiveFillAPress &&
          other.destructiveFillBPress == destructiveFillBPress &&
          other.destructiveRing == destructiveRing &&
          other.destructiveRingHover == destructiveRingHover &&
          other.dangerHover == dangerHover &&
          other.dangerPress == dangerPress &&
          other.remBgHover == remBgHover &&
          other.remBgPress == remBgPress &&
          other.error == error &&
          other.errorRing == errorRing &&
          other.thumb == thumb &&
          other.thumbEdge == thumbEdge &&
          other.track == track &&
          other.trackHover == trackHover &&
          other.trackEdge == trackEdge &&
          other.trackEdgeHover == trackEdgeHover &&
          other.tick == tick &&
          other.progressTrack == progressTrack &&
          other.scrollThumb == scrollThumb &&
          other.scrollThumbHover == scrollThumbHover &&
          other.scrollThumbDrag == scrollThumbDrag &&
          other.scrollTrack == scrollTrack &&
          other.tooltipBg == tooltipBg &&
          other.tooltipBorder == tooltipBorder &&
          other.skeleton == skeleton &&
          other.skeletonHi == skeletonHi &&
          other.selectionTextAlt == selectionTextAlt &&
          other.selectInactive == selectInactive;

  @override
  int get hashCode => Object.hashAll(<Object>[
    night0,
    night1,
    night2,
    night3,
    night4,
    night5,
    nightIcon,
    nightLift,
    paper0,
    paper1,
    paper2,
    paper3,
    paper4,
    paperInk,
    umber,
    gold50,
    gold200,
    gold400,
    gold600,
    goldInk,
    saffron,
    saffronPaper,
    moon,
    moonPaper,
    green400,
    green700,
    red400,
    red600,
    amber400,
    amberPaper,
    tlClose,
    tlMin,
    tlZoom,
    tlIdle,
    tlRing,
    canvas,
    canvasBase,
    gold,
    cardSolid,
    cardSolidHi,
    hatch,
    hatchMark,
    bgCard,
    bgCard2,
    border,
    borderStrong,
    codeBg,
    scrim,
    flBg,
    flBgStrong,
    flBgSolid,
    flBorder,
    flSheen,
    flHover,
    flOn,
    primaryAction,
    atChrome,
    atChromeEdge,
    text,
    textMuted,
    textDim,
    textFaint,
    edge,
    edgeHov,
    co,
    coSoft,
    coDeep,
    coGlow,
    coText,
    coInk,
    accent,
    accentInk,
    accentLine,
    accentText,
    accentSoft,
    accentSoftHi,
    accentRing,
    accentSelect,
    accentLiveLine,
    accentLiveRing,
    accentLiveText,
    statusM,
    statusMBg,
    hunk,
    hunkBg,
    remote,
    projClean,
    projDirty,
    projAhead,
    projBehind,
    projDiverged,
    projConflict,
    projMissing,
    projSyncing,
    projStale,
    add,
    addBg,
    rem,
    remBg,
    addBgHi,
    addEdge,
    addRing,
    conflict,
    warn,
    warnBg,
    focusRing,
    flPress,
    flOnHover,
    fillOnHover,
    fillOnPress,
    addInk,
    fieldBg,
    segInsetBg,
    primaryFillA,
    primaryFillB,
    primaryFillAHover,
    primaryFillBHover,
    primaryFillAPress,
    primaryFillBPress,
    primaryRing,
    primaryRingHover,
    primaryIcon,
    destructiveFillA,
    destructiveFillB,
    destructiveFillAHover,
    destructiveFillBHover,
    destructiveFillAPress,
    destructiveFillBPress,
    destructiveRing,
    destructiveRingHover,
    dangerHover,
    dangerPress,
    remBgHover,
    remBgPress,
    error,
    errorRing,
    thumb,
    thumbEdge,
    track,
    trackHover,
    trackEdge,
    trackEdgeHover,
    tick,
    progressTrack,
    scrollThumb,
    scrollThumbHover,
    scrollThumbDrag,
    scrollTrack,
    tooltipBg,
    tooltipBorder,
    skeleton,
    skeletonHi,
    selectionTextAlt,
    selectInactive,
  ]);
}
