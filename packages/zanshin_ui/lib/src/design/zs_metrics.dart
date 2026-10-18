// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import 'zs_appearance.dart';

/// The six icon sizes (DS tokens/spacing.css:17-23): the set is drawn on 16, the size follows the control.
enum ZsIconSize {
  /// `--icon-xs` (DS tokens/spacing.css:18).
  xs(10),

  /// `--icon-sm` (DS tokens/spacing.css:19).
  sm(12),

  /// `--icon-md` (DS tokens/spacing.css:20).
  md(14),

  /// `--icon-lg` (DS tokens/spacing.css:21).
  lg(16),

  /// `--icon-bar` (DS tokens/spacing.css:22).
  bar(17),

  /// `--icon-rail` (DS tokens/spacing.css:23).
  rail(19),
  ;

  const ZsIconSize(this.size);

  /// The side in logical pixels.
  final double size;
}

/// The design system's geometry: spacing, control heights, the chrome geometry derived from the traffic lights,
/// panel ranges, card and graph defaults (DS tokens/spacing.css), the radii and layers (tokens/effects.css:5-22,
/// :40-48) and the focus, disabled and scroll-bar values (tokens/states.css:17-26, :59). Lengths are logical
/// pixels; names follow the CSS (`--space-0-5` → [space05]).
///
/// [standard] is the window-mode set with the reference traffic-light geometry; [ZsMetrics.of] applies increased
/// contrast (`--focus-w` 3, DS tokens/contrast.css:21), full screen (DS tokens/spacing.css:52) and the measured
/// traffic-light block (DS tokens/spacing.css:25-30) from the nearest [ZsAppearance].
@immutable
class ZsMetrics {
  /// Creates a metric set; the app uses [standard] and [ZsMetrics.resolve].
  const ZsMetrics({
    required this.focusW,
    required this.focusOffset,
    required this.focusOffsetInset,
    required this.focusOffsetCard,
    required this.focusSettle,
    required this.fieldHalo,
    required this.disabledOpacity,
    required this.scrollW,
    required this.scrollWHover,
    required this.scrollGutter,
    required this.space0,
    required this.spacePx,
    required this.space05,
    required this.space1,
    required this.space15,
    required this.space2,
    required this.space25,
    required this.space3,
    required this.space35,
    required this.space4,
    required this.space5,
    required this.space6,
    required this.space7,
    required this.space8,
    required this.controlXs,
    required this.controlSm,
    required this.controlMd,
    required this.controlLg,
    required this.controlXl,
    required this.tlSize,
    required this.tlPitch,
    required this.tlX,
    required this.tlBlockW,
    required this.tlMidY,
    required this.chromeInset,
    required this.chromeRailBtn,
    required this.chromeCol,
    required this.chromeLeft,
    required this.windowHdH,
    required this.inspectorW,
    required this.inspectorWMin,
    required this.inspectorWMax,
    required this.panelW,
    required this.panelWMin,
    required this.panelWMax,
    required this.graphMinW,
    required this.resizeHit,
    required this.resizeHitOut,
    required this.minimapW,
    required this.cardW,
    required this.cardHCompact,
    required this.cardHDetailed,
    required this.cardPadX,
    required this.graphGapX,
    required this.graphGapY,
    required this.graphPad,
    required this.radiusKbd,
    required this.radiusXs,
    required this.radiusTag,
    required this.radiusSm,
    required this.radiusChip,
    required this.radiusMd,
    required this.radiusBtn,
    required this.radiusCard,
    required this.radiusRail,
    required this.radiusWell,
    required this.radiusPopover,
    required this.radiusIsland,
    required this.radiusPanel,
    required this.radiusDialog,
    required this.radiusPill,
    required this.radiusIcon,
    required this.zChrome,
    required this.zPreview,
    required this.zDialog,
    required this.zMenu,
    required this.zDrop,
    required this.zTooltip,
    required this.zDrag,
  });

  /// The metrics [appearance] shows: full screen moves the chrome, a measured traffic-light block places it,
  /// increased contrast widens the focus ring.
  factory ZsMetrics.resolve(ZsAppearance appearance) {
    ZsMetrics metrics = standard;
    final Rect? block = appearance.trafficLights;
    if (appearance.fullScreen) {
      // DS tokens/spacing.css:52; the chrome values derived from the block follow.
      metrics = metrics.copyWith(tlBlockW: 0, tlX: 0, tlMidY: 34);
    } else if (block != null) {
      // DS tokens/spacing.css:25-30: the bar derives from the system's block, the reference only stands in for it.
      // `tlSize` and `tlPitch` keep the reference: only mocks draw the buttons.
      metrics = metrics.copyWith(tlX: block.left, tlBlockW: block.width, tlMidY: block.center.dy);
    }
    if (appearance.increasedContrast) {
      // DS tokens/contrast.css:21.
      metrics = metrics.copyWith(focusW: 3);
    }
    return metrics;
  }

  /// The metrics of the nearest [ZsAppearance], or [standard] without one.
  factory ZsMetrics.of(BuildContext context) {
    final ZsAppearance? appearance = ZsAppearance.maybeOf(context);
    return appearance == null ? standard : ZsMetrics.resolve(appearance);
  }

  /// The window-mode metrics.
  static const standard = ZsMetrics(
    focusW: 2,
    focusOffset: 2,
    focusOffsetInset: -2,
    focusOffsetCard: 3,
    focusSettle: 3,
    fieldHalo: 3,
    disabledOpacity: .4,
    scrollW: 6,
    scrollWHover: 10,
    scrollGutter: 14,
    space0: 0,
    spacePx: 1,
    space05: 2,
    space1: 4,
    space15: 6,
    space2: 8,
    space25: 10,
    space3: 12,
    space35: 14,
    space4: 16,
    space5: 20,
    space6: 24,
    space7: 28,
    space8: 32,
    controlXs: 22,
    controlSm: 26,
    controlMd: 30,
    controlLg: 36,
    controlXl: 44,
    tlSize: 14,
    tlPitch: 23,
    tlX: 19,
    tlBlockW: 60,
    tlMidY: 26,
    chromeInset: 12,
    chromeRailBtn: 40,
    chromeCol: 52,
    chromeLeft: 76,
    windowHdH: 52,
    inspectorW: 460,
    inspectorWMin: 380,
    inspectorWMax: 720,
    panelW: 300,
    panelWMin: 240,
    panelWMax: 440,
    graphMinW: 320,
    resizeHit: 10,
    resizeHitOut: 7,
    minimapW: 134,
    cardW: 240,
    cardHCompact: 40,
    cardHDetailed: 62,
    cardPadX: 12,
    graphGapX: 56,
    graphGapY: 48,
    graphPad: 56,
    radiusKbd: 3,
    radiusXs: 4,
    radiusTag: 5,
    radiusSm: 6,
    radiusChip: 7,
    radiusMd: 8,
    radiusBtn: 9,
    radiusCard: 10,
    radiusRail: 11,
    radiusWell: 12,
    radiusPopover: 13,
    radiusIsland: 14,
    radiusPanel: 16,
    radiusDialog: 18,
    radiusPill: 999,
    radiusIcon: 22.66,
    zChrome: 20,
    zPreview: 40,
    zDialog: 50,
    zMenu: 60,
    zDrop: 70,
    zTooltip: 80,
    zDrag: 90,
  );

  /// `--focus-w` (DS tokens/states.css:18).
  final double focusW;

  /// `--focus-offset` (DS tokens/states.css:19).
  final double focusOffset;

  /// `--focus-offset-inset` (DS tokens/states.css:20).
  final double focusOffsetInset;

  /// `--focus-offset-card` (DS tokens/states.css:21).
  final double focusOffsetCard;

  /// `--focus-settle` (DS tokens/states.css:22).
  final double focusSettle;

  /// `--field-halo` (DS tokens/states.css:23).
  final double fieldHalo;

  /// `--disabled-opacity` (DS tokens/states.css:26).
  final double disabledOpacity;

  /// `--scroll-w` (DS tokens/states.css:59).
  final double scrollW;

  /// `--scroll-w-hover` (DS tokens/states.css:59).
  final double scrollWHover;

  /// `--scroll-gutter` (DS tokens/states.css:59).
  final double scrollGutter;

  /// `--space-0` (DS tokens/spacing.css:7).
  final double space0;

  /// `--space-px` (DS tokens/spacing.css:7).
  final double spacePx;

  /// `--space-0-5` (DS tokens/spacing.css:7).
  final double space05;

  /// `--space-1` (DS tokens/spacing.css:7).
  final double space1;

  /// `--space-1-5` (DS tokens/spacing.css:7).
  final double space15;

  /// `--space-2` (DS tokens/spacing.css:7).
  final double space2;

  /// `--space-2-5` (DS tokens/spacing.css:7).
  final double space25;

  /// `--space-3` (DS tokens/spacing.css:7).
  final double space3;

  /// `--space-3-5` (DS tokens/spacing.css:7).
  final double space35;

  /// `--space-4` (DS tokens/spacing.css:7).
  final double space4;

  /// `--space-5` (DS tokens/spacing.css:7).
  final double space5;

  /// `--space-6` (DS tokens/spacing.css:7).
  final double space6;

  /// `--space-7` (DS tokens/spacing.css:7).
  final double space7;

  /// `--space-8` (DS tokens/spacing.css:7).
  final double space8;

  /// `--control-xs` (DS tokens/spacing.css:11).
  final double controlXs;

  /// `--control-sm` (DS tokens/spacing.css:12).
  final double controlSm;

  /// `--control-md` (DS tokens/spacing.css:13).
  final double controlMd;

  /// `--control-lg` (DS tokens/spacing.css:14).
  final double controlLg;

  /// `--control-xl` (DS tokens/spacing.css:15).
  final double controlXl;

  /// `--tl-size` (DS tokens/spacing.css:31).
  final double tlSize;

  /// `--tl-pitch` (DS tokens/spacing.css:31).
  final double tlPitch;

  /// `--tl-x` (DS tokens/spacing.css:31).
  final double tlX;

  /// `--tl-block-w` (DS tokens/spacing.css:31).
  final double tlBlockW;

  /// `--tl-mid-y` (DS tokens/spacing.css:31).
  final double tlMidY;

  /// `--chrome-inset` (DS tokens/spacing.css:32).
  final double chromeInset;

  /// `--chrome-h` (DS tokens/spacing.css:33).
  double get chromeH => controlXl;

  /// `--chrome-control` (DS tokens/spacing.css:34).
  double get chromeControl => controlLg;

  /// `--chrome-rail-btn` (DS tokens/spacing.css:35).
  final double chromeRailBtn;

  /// `--chrome-col` (DS tokens/spacing.css:36).
  final double chromeCol;

  /// `--chrome-first-x` (DS tokens/spacing.css:37).
  double get chromeFirstX => tlX + tlBlockW + chromeInset;

  /// `--chrome-bar-y` (DS tokens/spacing.css:38).
  double get chromeBarY => tlMidY - chromeH / 2;

  /// `--chrome-top` (DS tokens/spacing.css:39).
  double get chromeTop => tlMidY + chromeH / 2 + chromeInset;

  /// `--chrome-left` (DS tokens/spacing.css:40).
  final double chromeLeft;

  /// `--window-hd-h` (DS tokens/spacing.css:41).
  final double windowHdH;

  /// `--inspector-w` (DS tokens/spacing.css:42).
  final double inspectorW;

  /// `--inspector-w-min` (DS tokens/spacing.css:42).
  final double inspectorWMin;

  /// `--inspector-w-max` (DS tokens/spacing.css:42).
  final double inspectorWMax;

  /// `--panel-w` (DS tokens/spacing.css:42).
  final double panelW;

  /// `--panel-w-min` (DS tokens/spacing.css:42).
  final double panelWMin;

  /// `--panel-w-max` (DS tokens/spacing.css:42).
  final double panelWMax;

  /// `--graph-min-w` (DS tokens/spacing.css:43).
  final double graphMinW;

  /// `--resize-hit` (DS tokens/spacing.css:44).
  final double resizeHit;

  /// `--resize-hit-out` (DS tokens/spacing.css:44).
  final double resizeHitOut;

  /// `--minimap-w` (DS tokens/spacing.css:45).
  final double minimapW;

  /// `--card-w` (DS tokens/spacing.css:47).
  final double cardW;

  /// `--card-h-compact` (DS tokens/spacing.css:47).
  final double cardHCompact;

  /// `--card-h-detailed` (DS tokens/spacing.css:47).
  final double cardHDetailed;

  /// `--card-pad-x` (DS tokens/spacing.css:47).
  final double cardPadX;

  /// `--graph-gap-x` (DS tokens/spacing.css:48).
  final double graphGapX;

  /// `--graph-gap-y` (DS tokens/spacing.css:48).
  final double graphGapY;

  /// `--graph-pad` (DS tokens/spacing.css:48).
  final double graphPad;

  /// `--radius-kbd` (DS tokens/effects.css:7).
  final double radiusKbd;

  /// `--radius-xs` (DS tokens/effects.css:8).
  final double radiusXs;

  /// `--radius-tag` (DS tokens/effects.css:9).
  final double radiusTag;

  /// `--radius-sm` (DS tokens/effects.css:10).
  final double radiusSm;

  /// `--radius-chip` (DS tokens/effects.css:11).
  final double radiusChip;

  /// `--radius-md` (DS tokens/effects.css:12).
  final double radiusMd;

  /// `--radius-btn` (DS tokens/effects.css:13).
  final double radiusBtn;

  /// `--radius-card` (DS tokens/effects.css:14).
  final double radiusCard;

  /// `--radius-rail` (DS tokens/effects.css:15).
  final double radiusRail;

  /// `--radius-well` (DS tokens/effects.css:16).
  final double radiusWell;

  /// `--radius-popover` (DS tokens/effects.css:17).
  final double radiusPopover;

  /// `--radius-island` (DS tokens/effects.css:18).
  final double radiusIsland;

  /// `--radius-panel` (DS tokens/effects.css:19).
  final double radiusPanel;

  /// `--radius-dialog` (DS tokens/effects.css:20).
  final double radiusDialog;

  /// `--radius-pill` (DS tokens/effects.css:21).
  final double radiusPill;

  /// `--radius-icon`, in percent of the icon's side (DS tokens/effects.css:22).
  final double radiusIcon;

  /// `--z-chrome` (DS tokens/effects.css:42).
  final int zChrome;

  /// `--z-preview` (DS tokens/effects.css:43).
  final int zPreview;

  /// `--z-dialog` (DS tokens/effects.css:44).
  final int zDialog;

  /// `--z-menu` (DS tokens/effects.css:45).
  final int zMenu;

  /// `--z-drop` (DS tokens/effects.css:46).
  final int zDrop;

  /// `--z-tooltip` (DS tokens/effects.css:47).
  final int zTooltip;

  /// `--z-drag` (DS tokens/effects.css:48).
  final int zDrag;

  /// Returns a copy with the given values replaced.
  ZsMetrics copyWith({
    double? focusW,
    double? focusOffset,
    double? focusOffsetInset,
    double? focusOffsetCard,
    double? focusSettle,
    double? fieldHalo,
    double? disabledOpacity,
    double? scrollW,
    double? scrollWHover,
    double? scrollGutter,
    double? space0,
    double? spacePx,
    double? space05,
    double? space1,
    double? space15,
    double? space2,
    double? space25,
    double? space3,
    double? space35,
    double? space4,
    double? space5,
    double? space6,
    double? space7,
    double? space8,
    double? controlXs,
    double? controlSm,
    double? controlMd,
    double? controlLg,
    double? controlXl,
    double? tlSize,
    double? tlPitch,
    double? tlX,
    double? tlBlockW,
    double? tlMidY,
    double? chromeInset,
    double? chromeRailBtn,
    double? chromeCol,
    double? chromeLeft,
    double? windowHdH,
    double? inspectorW,
    double? inspectorWMin,
    double? inspectorWMax,
    double? panelW,
    double? panelWMin,
    double? panelWMax,
    double? graphMinW,
    double? resizeHit,
    double? resizeHitOut,
    double? minimapW,
    double? cardW,
    double? cardHCompact,
    double? cardHDetailed,
    double? cardPadX,
    double? graphGapX,
    double? graphGapY,
    double? graphPad,
    double? radiusKbd,
    double? radiusXs,
    double? radiusTag,
    double? radiusSm,
    double? radiusChip,
    double? radiusMd,
    double? radiusBtn,
    double? radiusCard,
    double? radiusRail,
    double? radiusWell,
    double? radiusPopover,
    double? radiusIsland,
    double? radiusPanel,
    double? radiusDialog,
    double? radiusPill,
    double? radiusIcon,
    int? zChrome,
    int? zPreview,
    int? zDialog,
    int? zMenu,
    int? zDrop,
    int? zTooltip,
    int? zDrag,
  }) => ZsMetrics(
    focusW: focusW ?? this.focusW,
    focusOffset: focusOffset ?? this.focusOffset,
    focusOffsetInset: focusOffsetInset ?? this.focusOffsetInset,
    focusOffsetCard: focusOffsetCard ?? this.focusOffsetCard,
    focusSettle: focusSettle ?? this.focusSettle,
    fieldHalo: fieldHalo ?? this.fieldHalo,
    disabledOpacity: disabledOpacity ?? this.disabledOpacity,
    scrollW: scrollW ?? this.scrollW,
    scrollWHover: scrollWHover ?? this.scrollWHover,
    scrollGutter: scrollGutter ?? this.scrollGutter,
    space0: space0 ?? this.space0,
    spacePx: spacePx ?? this.spacePx,
    space05: space05 ?? this.space05,
    space1: space1 ?? this.space1,
    space15: space15 ?? this.space15,
    space2: space2 ?? this.space2,
    space25: space25 ?? this.space25,
    space3: space3 ?? this.space3,
    space35: space35 ?? this.space35,
    space4: space4 ?? this.space4,
    space5: space5 ?? this.space5,
    space6: space6 ?? this.space6,
    space7: space7 ?? this.space7,
    space8: space8 ?? this.space8,
    controlXs: controlXs ?? this.controlXs,
    controlSm: controlSm ?? this.controlSm,
    controlMd: controlMd ?? this.controlMd,
    controlLg: controlLg ?? this.controlLg,
    controlXl: controlXl ?? this.controlXl,
    tlSize: tlSize ?? this.tlSize,
    tlPitch: tlPitch ?? this.tlPitch,
    tlX: tlX ?? this.tlX,
    tlBlockW: tlBlockW ?? this.tlBlockW,
    tlMidY: tlMidY ?? this.tlMidY,
    chromeInset: chromeInset ?? this.chromeInset,
    chromeRailBtn: chromeRailBtn ?? this.chromeRailBtn,
    chromeCol: chromeCol ?? this.chromeCol,
    chromeLeft: chromeLeft ?? this.chromeLeft,
    windowHdH: windowHdH ?? this.windowHdH,
    inspectorW: inspectorW ?? this.inspectorW,
    inspectorWMin: inspectorWMin ?? this.inspectorWMin,
    inspectorWMax: inspectorWMax ?? this.inspectorWMax,
    panelW: panelW ?? this.panelW,
    panelWMin: panelWMin ?? this.panelWMin,
    panelWMax: panelWMax ?? this.panelWMax,
    graphMinW: graphMinW ?? this.graphMinW,
    resizeHit: resizeHit ?? this.resizeHit,
    resizeHitOut: resizeHitOut ?? this.resizeHitOut,
    minimapW: minimapW ?? this.minimapW,
    cardW: cardW ?? this.cardW,
    cardHCompact: cardHCompact ?? this.cardHCompact,
    cardHDetailed: cardHDetailed ?? this.cardHDetailed,
    cardPadX: cardPadX ?? this.cardPadX,
    graphGapX: graphGapX ?? this.graphGapX,
    graphGapY: graphGapY ?? this.graphGapY,
    graphPad: graphPad ?? this.graphPad,
    radiusKbd: radiusKbd ?? this.radiusKbd,
    radiusXs: radiusXs ?? this.radiusXs,
    radiusTag: radiusTag ?? this.radiusTag,
    radiusSm: radiusSm ?? this.radiusSm,
    radiusChip: radiusChip ?? this.radiusChip,
    radiusMd: radiusMd ?? this.radiusMd,
    radiusBtn: radiusBtn ?? this.radiusBtn,
    radiusCard: radiusCard ?? this.radiusCard,
    radiusRail: radiusRail ?? this.radiusRail,
    radiusWell: radiusWell ?? this.radiusWell,
    radiusPopover: radiusPopover ?? this.radiusPopover,
    radiusIsland: radiusIsland ?? this.radiusIsland,
    radiusPanel: radiusPanel ?? this.radiusPanel,
    radiusDialog: radiusDialog ?? this.radiusDialog,
    radiusPill: radiusPill ?? this.radiusPill,
    radiusIcon: radiusIcon ?? this.radiusIcon,
    zChrome: zChrome ?? this.zChrome,
    zPreview: zPreview ?? this.zPreview,
    zDialog: zDialog ?? this.zDialog,
    zMenu: zMenu ?? this.zMenu,
    zDrop: zDrop ?? this.zDrop,
    zTooltip: zTooltip ?? this.zTooltip,
    zDrag: zDrag ?? this.zDrag,
  );

  /// Every token as `'--name' → value`; for the DS parity test.
  Map<String, Object> toCss() => <String, Object>{
    '--focus-w': focusW,
    '--focus-offset': focusOffset,
    '--focus-offset-inset': focusOffsetInset,
    '--focus-offset-card': focusOffsetCard,
    '--focus-settle': focusSettle,
    '--field-halo': fieldHalo,
    '--disabled-opacity': disabledOpacity,
    '--scroll-w': scrollW,
    '--scroll-w-hover': scrollWHover,
    '--scroll-gutter': scrollGutter,
    '--space-0': space0,
    '--space-px': spacePx,
    '--space-0-5': space05,
    '--space-1': space1,
    '--space-1-5': space15,
    '--space-2': space2,
    '--space-2-5': space25,
    '--space-3': space3,
    '--space-3-5': space35,
    '--space-4': space4,
    '--space-5': space5,
    '--space-6': space6,
    '--space-7': space7,
    '--space-8': space8,
    '--control-xs': controlXs,
    '--control-sm': controlSm,
    '--control-md': controlMd,
    '--control-lg': controlLg,
    '--control-xl': controlXl,
    '--icon-xs': ZsIconSize.xs.size,
    '--icon-sm': ZsIconSize.sm.size,
    '--icon-md': ZsIconSize.md.size,
    '--icon-lg': ZsIconSize.lg.size,
    '--icon-bar': ZsIconSize.bar.size,
    '--icon-rail': ZsIconSize.rail.size,
    '--tl-size': tlSize,
    '--tl-pitch': tlPitch,
    '--tl-x': tlX,
    '--tl-block-w': tlBlockW,
    '--tl-mid-y': tlMidY,
    '--chrome-inset': chromeInset,
    '--chrome-h': chromeH,
    '--chrome-control': chromeControl,
    '--chrome-rail-btn': chromeRailBtn,
    '--chrome-col': chromeCol,
    '--chrome-first-x': chromeFirstX,
    '--chrome-bar-y': chromeBarY,
    '--chrome-top': chromeTop,
    '--chrome-left': chromeLeft,
    '--window-hd-h': windowHdH,
    '--inspector-w': inspectorW,
    '--inspector-w-min': inspectorWMin,
    '--inspector-w-max': inspectorWMax,
    '--panel-w': panelW,
    '--panel-w-min': panelWMin,
    '--panel-w-max': panelWMax,
    '--graph-min-w': graphMinW,
    '--resize-hit': resizeHit,
    '--resize-hit-out': resizeHitOut,
    '--minimap-w': minimapW,
    '--card-w': cardW,
    '--card-h-compact': cardHCompact,
    '--card-h-detailed': cardHDetailed,
    '--card-pad-x': cardPadX,
    '--graph-gap-x': graphGapX,
    '--graph-gap-y': graphGapY,
    '--graph-pad': graphPad,
    '--radius-kbd': radiusKbd,
    '--radius-xs': radiusXs,
    '--radius-tag': radiusTag,
    '--radius-sm': radiusSm,
    '--radius-chip': radiusChip,
    '--radius-md': radiusMd,
    '--radius-btn': radiusBtn,
    '--radius-card': radiusCard,
    '--radius-rail': radiusRail,
    '--radius-well': radiusWell,
    '--radius-popover': radiusPopover,
    '--radius-island': radiusIsland,
    '--radius-panel': radiusPanel,
    '--radius-dialog': radiusDialog,
    '--radius-pill': radiusPill,
    '--radius-icon': radiusIcon,
    '--z-chrome': zChrome,
    '--z-preview': zPreview,
    '--z-dialog': zDialog,
    '--z-menu': zMenu,
    '--z-drop': zDrop,
    '--z-tooltip': zTooltip,
    '--z-drag': zDrag,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsMetrics &&
          other.focusW == focusW &&
          other.focusOffset == focusOffset &&
          other.focusOffsetInset == focusOffsetInset &&
          other.focusOffsetCard == focusOffsetCard &&
          other.focusSettle == focusSettle &&
          other.fieldHalo == fieldHalo &&
          other.disabledOpacity == disabledOpacity &&
          other.scrollW == scrollW &&
          other.scrollWHover == scrollWHover &&
          other.scrollGutter == scrollGutter &&
          other.space0 == space0 &&
          other.spacePx == spacePx &&
          other.space05 == space05 &&
          other.space1 == space1 &&
          other.space15 == space15 &&
          other.space2 == space2 &&
          other.space25 == space25 &&
          other.space3 == space3 &&
          other.space35 == space35 &&
          other.space4 == space4 &&
          other.space5 == space5 &&
          other.space6 == space6 &&
          other.space7 == space7 &&
          other.space8 == space8 &&
          other.controlXs == controlXs &&
          other.controlSm == controlSm &&
          other.controlMd == controlMd &&
          other.controlLg == controlLg &&
          other.controlXl == controlXl &&
          other.tlSize == tlSize &&
          other.tlPitch == tlPitch &&
          other.tlX == tlX &&
          other.tlBlockW == tlBlockW &&
          other.tlMidY == tlMidY &&
          other.chromeInset == chromeInset &&
          other.chromeRailBtn == chromeRailBtn &&
          other.chromeCol == chromeCol &&
          other.chromeLeft == chromeLeft &&
          other.windowHdH == windowHdH &&
          other.inspectorW == inspectorW &&
          other.inspectorWMin == inspectorWMin &&
          other.inspectorWMax == inspectorWMax &&
          other.panelW == panelW &&
          other.panelWMin == panelWMin &&
          other.panelWMax == panelWMax &&
          other.graphMinW == graphMinW &&
          other.resizeHit == resizeHit &&
          other.resizeHitOut == resizeHitOut &&
          other.minimapW == minimapW &&
          other.cardW == cardW &&
          other.cardHCompact == cardHCompact &&
          other.cardHDetailed == cardHDetailed &&
          other.cardPadX == cardPadX &&
          other.graphGapX == graphGapX &&
          other.graphGapY == graphGapY &&
          other.graphPad == graphPad &&
          other.radiusKbd == radiusKbd &&
          other.radiusXs == radiusXs &&
          other.radiusTag == radiusTag &&
          other.radiusSm == radiusSm &&
          other.radiusChip == radiusChip &&
          other.radiusMd == radiusMd &&
          other.radiusBtn == radiusBtn &&
          other.radiusCard == radiusCard &&
          other.radiusRail == radiusRail &&
          other.radiusWell == radiusWell &&
          other.radiusPopover == radiusPopover &&
          other.radiusIsland == radiusIsland &&
          other.radiusPanel == radiusPanel &&
          other.radiusDialog == radiusDialog &&
          other.radiusPill == radiusPill &&
          other.radiusIcon == radiusIcon &&
          other.zChrome == zChrome &&
          other.zPreview == zPreview &&
          other.zDialog == zDialog &&
          other.zMenu == zMenu &&
          other.zDrop == zDrop &&
          other.zTooltip == zTooltip &&
          other.zDrag == zDrag;

  @override
  int get hashCode => Object.hashAll(<Object>[
    focusW,
    focusOffset,
    focusOffsetInset,
    focusOffsetCard,
    focusSettle,
    fieldHalo,
    disabledOpacity,
    scrollW,
    scrollWHover,
    scrollGutter,
    space0,
    spacePx,
    space05,
    space1,
    space15,
    space2,
    space25,
    space3,
    space35,
    space4,
    space5,
    space6,
    space7,
    space8,
    controlXs,
    controlSm,
    controlMd,
    controlLg,
    controlXl,
    tlSize,
    tlPitch,
    tlX,
    tlBlockW,
    tlMidY,
    chromeInset,
    chromeRailBtn,
    chromeCol,
    chromeLeft,
    windowHdH,
    inspectorW,
    inspectorWMin,
    inspectorWMax,
    panelW,
    panelWMin,
    panelWMax,
    graphMinW,
    resizeHit,
    resizeHitOut,
    minimapW,
    cardW,
    cardHCompact,
    cardHDetailed,
    cardPadX,
    graphGapX,
    graphGapY,
    graphPad,
    radiusKbd,
    radiusXs,
    radiusTag,
    radiusSm,
    radiusChip,
    radiusMd,
    radiusBtn,
    radiusCard,
    radiusRail,
    radiusWell,
    radiusPopover,
    radiusIsland,
    radiusPanel,
    radiusDialog,
    radiusPill,
    radiusIcon,
    zChrome,
    zPreview,
    zDialog,
    zMenu,
    zDrop,
    zTooltip,
    zDrag,
  ]);
}
