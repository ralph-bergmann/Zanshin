// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeExtension;

import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_values.dart';

/// The design system's elevation: every shadow and ring (DS tokens/effects.css:24-34, paper :50-60; the thumb
/// and tooltip shadows of tokens/states.css:51-52, :63, paper :92-93, :97) and the glass and scrim blurs
/// (tokens/effects.css:36-38). Paper uses umber where night uses black.
///
/// [ZsElevation.resolve] rebuilds the rings from the resolved colours, so they follow the accent family and the
/// inactive window, and drops every blur (null) under increased contrast or reduce transparency
/// (DS tokens/contrast.css:21-22, tokens/transparency.css:9-10). [of] falls back to [night].
@immutable
class ZsElevation extends ThemeExtension<ZsElevation> {
  /// Creates an elevation set; the app uses [night], [paper] and [ZsElevation.resolve].
  const ZsElevation({
    required this.thumbShadow,
    required this.thumbShadowHover,
    required this.shadowTooltip,
    required this.flShadow,
    required this.shadowMenu,
    required this.shadowDialog,
    required this.shadowMark,
    required this.shadowDrag,
    required this.ringSelect,
    required this.ringWc,
    required this.ringWcSelect,
    required this.ringDrop,
    required this.glassBlur,
    required this.glassBlurStrong,
    required this.scrimBlur,
  });

  /// The elevation [appearance] shows.
  factory ZsElevation.resolve(ZsAppearance appearance) {
    final colors = ZsColors.resolve(appearance);
    final onPaper = appearance.theme == ZsTheme.paper;
    final ZsElevation base = onPaper ? paper : night;
    final bool solid = appearance.increasedContrast || appearance.reduceTransparency;
    return ZsElevation(
      thumbShadow: base.thumbShadow,
      thumbShadowHover: base.thumbShadowHover,
      shadowTooltip: base.shadowTooltip,
      flShadow: base.flShadow,
      shadowMenu: base.shadowMenu,
      shadowDialog: base.shadowDialog,
      shadowMark: base.shadowMark,
      shadowDrag: ZsShadowStack(<ZsShadow>[
        ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: colors.accentRing),
        if (onPaper) _paperDragDrop else _nightDragDrop,
      ]),
      ringSelect: ZsShadowStack(<ZsShadow>[ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: colors.accentRing)]),
      ringWc: base.ringWc,
      ringWcSelect: ZsShadowStack(<ZsShadow>[
        ZsShadow(dx: 0, dy: 0, blur: 0, spread: 1, color: colors.coDeep),
        ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: colors.accentRing),
      ]),
      ringDrop: ZsShadowStack(<ZsShadow>[
        ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: colors.accentLiveRing),
        if (onPaper) _paperDropDrop else _nightDropDrop,
      ]),
      glassBlur: solid ? null : base.glassBlur,
      glassBlurStrong: solid ? null : base.glassBlurStrong,
      scrimBlur: solid ? null : base.scrimBlur,
    );
  }

  /// Night under Multicolor.
  static const night = ZsElevation(
    thumbShadow: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(0, 0, 0, .5)),
    ]),
    thumbShadowHover: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 4, spread: 0, color: Color.fromRGBO(0, 0, 0, .6)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(255, 255, 255, .06)),
    ]),
    shadowTooltip: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 8, blur: 22, spread: -8, color: Color.fromRGBO(0, 0, 0, .6)),
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(0, 0, 0, .3)),
    ]),
    flShadow: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 0, spread: 0, color: Color.fromRGBO(255, 255, 255, .05), inset: true),
      ZsShadow(dx: 0, dy: 14, blur: 36, spread: -12, color: Color.fromRGBO(0, 0, 0, .6)),
      ZsShadow(dx: 0, dy: 2, blur: 8, spread: 0, color: Color.fromRGBO(0, 0, 0, .22)),
    ]),
    shadowMenu: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 24, blur: 60, spread: -16, color: Color.fromRGBO(0, 0, 0, .6)),
      ZsShadow(dx: 0, dy: 2, blur: 8, spread: 0, color: Color.fromRGBO(0, 0, 0, .2)),
    ]),
    shadowDialog: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 40, blur: 100, spread: -24, color: Color.fromRGBO(0, 0, 0, .72)),
      ZsShadow(dx: 0, dy: 2, blur: 10, spread: 0, color: Color.fromRGBO(0, 0, 0, .2)),
    ]),
    shadowMark: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: .5, color: Color.fromRGBO(255, 255, 255, .16)),
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(0, 0, 0, .35)),
    ]),
    shadowDrag: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(174, 188, 236, .3)),
      ZsShadow(dx: 0, dy: 20, blur: 44, spread: -14, color: Color.fromRGBO(0, 0, 0, .6)),
    ]),
    ringSelect: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(174, 188, 236, .3)),
    ]),
    ringWc: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 1, color: Color.fromRGBO(242, 166, 24, .55)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(242, 166, 24, .30)),
      ZsShadow(dx: 0, dy: 8, blur: 28, spread: -10, color: Color.fromRGBO(242, 166, 24, .30)),
    ]),
    ringWcSelect: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 1, color: Color.fromRGBO(242, 166, 24, .55)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(174, 188, 236, .3)),
    ]),
    ringDrop: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(174, 188, 236, .3)),
      ZsShadow(dx: 0, dy: 14, blur: 32, spread: -14, color: Color.fromRGBO(0, 0, 0, .55)),
    ]),
    glassBlur: ZsGlassFilter(blur: 18, saturate: 1.4),
    glassBlurStrong: ZsGlassFilter(blur: 22, saturate: 1.4),
    scrimBlur: ZsGlassFilter(blur: 12, saturate: 1.2),
  );

  /// Paper under Multicolor.
  static const paper = ZsElevation(
    thumbShadow: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(58, 46, 34, .28)),
    ]),
    thumbShadowHover: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 4, spread: 0, color: Color.fromRGBO(58, 46, 34, .36)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(58, 46, 34, .06)),
    ]),
    shadowTooltip: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 8, blur: 22, spread: -8, color: Color.fromRGBO(58, 46, 34, .3)),
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(58, 46, 34, .12)),
    ]),
    flShadow: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 1, blur: 0, spread: 0, color: Color.fromRGBO(255, 255, 255, .8), inset: true),
      ZsShadow(dx: 0, dy: 14, blur: 34, spread: -14, color: Color.fromRGBO(58, 46, 34, .32)),
      ZsShadow(dx: 0, dy: 2, blur: 8, spread: 0, color: Color.fromRGBO(58, 46, 34, .08)),
    ]),
    shadowMenu: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 24, blur: 60, spread: -18, color: Color.fromRGBO(58, 46, 34, .3)),
      ZsShadow(dx: 0, dy: 2, blur: 8, spread: 0, color: Color.fromRGBO(58, 46, 34, .08)),
    ]),
    shadowDialog: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 40, blur: 100, spread: -28, color: Color.fromRGBO(58, 46, 34, .34)),
      ZsShadow(dx: 0, dy: 2, blur: 10, spread: 0, color: Color.fromRGBO(58, 46, 34, .08)),
    ]),
    shadowMark: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: .5, color: Color.fromRGBO(58, 46, 34, .22)),
      ZsShadow(dx: 0, dy: 1, blur: 3, spread: 0, color: Color.fromRGBO(58, 46, 34, .22)),
    ]),
    shadowDrag: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(71, 87, 161, .22)),
      ZsShadow(dx: 0, dy: 20, blur: 44, spread: -16, color: Color.fromRGBO(58, 46, 34, .35)),
    ]),
    ringSelect: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color.fromRGBO(71, 87, 161, .22)),
    ]),
    ringWc: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 1, color: Color.fromRGBO(165, 98, 5, .45)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(165, 98, 5, .22)),
      ZsShadow(dx: 0, dy: 8, blur: 28, spread: -10, color: Color.fromRGBO(165, 98, 5, .22)),
    ]),
    ringWcSelect: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 1, color: Color.fromRGBO(165, 98, 5, .45)),
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(71, 87, 161, .22)),
    ]),
    ringDrop: ZsShadowStack(<ZsShadow>[
      ZsShadow(dx: 0, dy: 0, blur: 0, spread: 4, color: Color.fromRGBO(71, 87, 161, .22)),
      ZsShadow(dx: 0, dy: 14, blur: 32, spread: -14, color: Color.fromRGBO(58, 46, 34, .3)),
    ]),
    glassBlur: ZsGlassFilter(blur: 18, saturate: 1.4),
    glassBlurStrong: ZsGlassFilter(blur: 22, saturate: 1.4),
    scrimBlur: ZsGlassFilter(blur: 12, saturate: 1.2),
  );

  /// The drop part of `--shadow-drag` on night (DS tokens/effects.css:30; paper :56).
  static const _nightDragDrop = ZsShadow(dx: 0, dy: 20, blur: 44, spread: -14, color: Color.fromRGBO(0, 0, 0, .6));

  /// The drop part of `--ring-drop` on night (DS tokens/effects.css:34; paper :60).
  static const _nightDropDrop = ZsShadow(dx: 0, dy: 14, blur: 32, spread: -14, color: Color.fromRGBO(0, 0, 0, .55));

  /// The drop part of `--shadow-drag` on paper (DS tokens/effects.css:30; paper :56).
  static const _paperDragDrop = ZsShadow(dx: 0, dy: 20, blur: 44, spread: -16, color: Color.fromRGBO(58, 46, 34, .35));

  /// The drop part of `--ring-drop` on paper (DS tokens/effects.css:34; paper :60).
  static const _paperDropDrop = ZsShadow(dx: 0, dy: 14, blur: 32, spread: -14, color: Color.fromRGBO(58, 46, 34, .3));

  /// The elevation of the nearest [Theme], or [night] when it carries none.
  static ZsElevation of(BuildContext context) => Theme.of(context).extension<ZsElevation>() ?? night;

  /// `--thumb-shadow` (DS tokens/states.css:51; paper :92).
  final ZsShadowStack thumbShadow;

  /// `--thumb-shadow-hover` (DS tokens/states.css:52; paper :93).
  final ZsShadowStack thumbShadowHover;

  /// `--shadow-tooltip` (DS tokens/states.css:63; paper :97).
  final ZsShadowStack shadowTooltip;

  /// `--fl-shadow` (DS tokens/effects.css:25; paper :51).
  final ZsShadowStack flShadow;

  /// `--shadow-island` = `--fl-shadow` (DS tokens/effects.css:26; paper :52).
  ZsShadowStack get shadowIsland => flShadow;

  /// `--shadow-menu` (DS tokens/effects.css:27; paper :53).
  final ZsShadowStack shadowMenu;

  /// `--shadow-dialog` (DS tokens/effects.css:28; paper :54).
  final ZsShadowStack shadowDialog;

  /// `--shadow-mark` (DS tokens/effects.css:29; paper :55).
  final ZsShadowStack shadowMark;

  /// `--shadow-drag` (DS tokens/effects.css:30; paper :56).
  final ZsShadowStack shadowDrag;

  /// `--ring-select` (DS tokens/effects.css:31; paper :57).
  final ZsShadowStack ringSelect;

  /// `--ring-wc` (DS tokens/effects.css:32; paper :58).
  final ZsShadowStack ringWc;

  /// `--ring-wc-select` (DS tokens/effects.css:33; paper :59).
  final ZsShadowStack ringWcSelect;

  /// `--ring-drop` (DS tokens/effects.css:34; paper :60).
  final ZsShadowStack ringDrop;

  /// `--glass-blur`; null for `none` (DS tokens/effects.css:36).
  final ZsGlassFilter? glassBlur;

  /// `--glass-blur-strong`; null for `none` (DS tokens/effects.css:37).
  final ZsGlassFilter? glassBlurStrong;

  /// `--scrim-blur`; null for `none` (DS tokens/effects.css:38).
  final ZsGlassFilter? scrimBlur;

  @override
  ZsElevation copyWith({
    ZsShadowStack? thumbShadow,
    ZsShadowStack? thumbShadowHover,
    ZsShadowStack? shadowTooltip,
    ZsShadowStack? flShadow,
    ZsShadowStack? shadowMenu,
    ZsShadowStack? shadowDialog,
    ZsShadowStack? shadowMark,
    ZsShadowStack? shadowDrag,
    ZsShadowStack? ringSelect,
    ZsShadowStack? ringWc,
    ZsShadowStack? ringWcSelect,
    ZsShadowStack? ringDrop,
    ZsGlassFilter? glassBlur,
    ZsGlassFilter? glassBlurStrong,
    ZsGlassFilter? scrimBlur,
  }) => ZsElevation(
    thumbShadow: thumbShadow ?? this.thumbShadow,
    thumbShadowHover: thumbShadowHover ?? this.thumbShadowHover,
    shadowTooltip: shadowTooltip ?? this.shadowTooltip,
    flShadow: flShadow ?? this.flShadow,
    shadowMenu: shadowMenu ?? this.shadowMenu,
    shadowDialog: shadowDialog ?? this.shadowDialog,
    shadowMark: shadowMark ?? this.shadowMark,
    shadowDrag: shadowDrag ?? this.shadowDrag,
    ringSelect: ringSelect ?? this.ringSelect,
    ringWc: ringWc ?? this.ringWc,
    ringWcSelect: ringWcSelect ?? this.ringWcSelect,
    ringDrop: ringDrop ?? this.ringDrop,
    glassBlur: glassBlur ?? this.glassBlur,
    glassBlurStrong: glassBlurStrong ?? this.glassBlurStrong,
    scrimBlur: scrimBlur ?? this.scrimBlur,
  );

  @override
  ZsElevation lerp(ZsElevation? other, double t) {
    if (other == null) {
      return this;
    }
    return ZsElevation(
      thumbShadow: ZsShadowStack.lerp(thumbShadow, other.thumbShadow, t),
      thumbShadowHover: ZsShadowStack.lerp(thumbShadowHover, other.thumbShadowHover, t),
      shadowTooltip: ZsShadowStack.lerp(shadowTooltip, other.shadowTooltip, t),
      flShadow: ZsShadowStack.lerp(flShadow, other.flShadow, t),
      shadowMenu: ZsShadowStack.lerp(shadowMenu, other.shadowMenu, t),
      shadowDialog: ZsShadowStack.lerp(shadowDialog, other.shadowDialog, t),
      shadowMark: ZsShadowStack.lerp(shadowMark, other.shadowMark, t),
      shadowDrag: ZsShadowStack.lerp(shadowDrag, other.shadowDrag, t),
      ringSelect: ZsShadowStack.lerp(ringSelect, other.ringSelect, t),
      ringWc: ZsShadowStack.lerp(ringWc, other.ringWc, t),
      ringWcSelect: ZsShadowStack.lerp(ringWcSelect, other.ringWcSelect, t),
      ringDrop: ZsShadowStack.lerp(ringDrop, other.ringDrop, t),
      glassBlur: ZsGlassFilter.lerp(glassBlur, other.glassBlur, t),
      glassBlurStrong: ZsGlassFilter.lerp(glassBlurStrong, other.glassBlurStrong, t),
      scrimBlur: ZsGlassFilter.lerp(scrimBlur, other.scrimBlur, t),
    );
  }

  /// Every token as `'--name' → value` (`none` → null); for the DS parity test.
  Map<String, Object?> toCss() => <String, Object?>{
    '--thumb-shadow': thumbShadow,
    '--thumb-shadow-hover': thumbShadowHover,
    '--shadow-tooltip': shadowTooltip,
    '--fl-shadow': flShadow,
    '--shadow-island': shadowIsland,
    '--shadow-menu': shadowMenu,
    '--shadow-dialog': shadowDialog,
    '--shadow-mark': shadowMark,
    '--shadow-drag': shadowDrag,
    '--ring-select': ringSelect,
    '--ring-wc': ringWc,
    '--ring-wc-select': ringWcSelect,
    '--ring-drop': ringDrop,
    '--glass-blur': glassBlur,
    '--glass-blur-strong': glassBlurStrong,
    '--scrim-blur': scrimBlur,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsElevation &&
          other.thumbShadow == thumbShadow &&
          other.thumbShadowHover == thumbShadowHover &&
          other.shadowTooltip == shadowTooltip &&
          other.flShadow == flShadow &&
          other.shadowMenu == shadowMenu &&
          other.shadowDialog == shadowDialog &&
          other.shadowMark == shadowMark &&
          other.shadowDrag == shadowDrag &&
          other.ringSelect == ringSelect &&
          other.ringWc == ringWc &&
          other.ringWcSelect == ringWcSelect &&
          other.ringDrop == ringDrop &&
          other.glassBlur == glassBlur &&
          other.glassBlurStrong == glassBlurStrong &&
          other.scrimBlur == scrimBlur;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    thumbShadow,
    thumbShadowHover,
    shadowTooltip,
    flShadow,
    shadowMenu,
    shadowDialog,
    shadowMark,
    shadowDrag,
    ringSelect,
    ringWc,
    ringWcSelect,
    ringDrop,
    glassBlur,
    glassBlurStrong,
    scrimBlur,
  ]);
}
