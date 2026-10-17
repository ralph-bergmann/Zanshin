// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// The design system's motion (DS tokens/motion.css:12-68): curves by job, the `--motion` factor, the fades,
/// the movement durations, the waits and holds, and calm scrolling.
///
/// Reduce motion is defined by property (decision 16.4; DS tokens/motion.css:3-10, :69-71): [reduced] sets
/// [motion] to 0 and the five movement durations to zero; every fade keeps its value. [of] picks [reduced]
/// exactly when `MediaQuery.disableAnimations` is on, which every window root sets from the shell.
enum ZsMotion {
  /// Full motion.
  full(
    easeState: Cubic(.25, .1, .25, 1),
    easeGlide: Cubic(.32, .72, 0, 1),
    easeExit: Cubic(.4, 0, 1, 1),
    easeLinear: Curves.linear,
    easeLoader: Cubic(.65, .05, .35, .95),
    motion: 1,
    durInstant: Duration.zero,
    durHover: Duration(milliseconds: 120),
    durFocus: Duration(milliseconds: 160),
    durBlink: Duration(milliseconds: 70),
    durMenu: Duration(milliseconds: 110),
    durPop: Duration(milliseconds: 160),
    durExit: Duration(milliseconds: 120),
    durExitLg: Duration(milliseconds: 180),
    durPanel: Duration(milliseconds: 200),
    durDialog: Duration(milliseconds: 220),
    durSlide: Duration(milliseconds: 260),
    durBirth: Duration(milliseconds: 540),
    durFlash: Duration(milliseconds: 2400),
    durSpin: Duration(milliseconds: 800),
    durShimmer: Duration(milliseconds: 1600),
    durNudge: Duration(milliseconds: 120),
    durToggle: Duration(milliseconds: 180),
    durExpand: Duration(milliseconds: 200),
    durMove: Duration(milliseconds: 260),
    durFlip: Duration(milliseconds: 460),
    delayTooltip: Duration(milliseconds: 700),
    durTooltipWarm: Duration(milliseconds: 600),
    delayPeek: Duration(milliseconds: 450),
    delayStackList: Duration(milliseconds: 380),
    delayCallout: Duration(milliseconds: 90),
    delayCalloutOut: Duration(milliseconds: 200),
    delayDropMenu: Duration(milliseconds: 520),
    delaySubmenu: Duration(milliseconds: 150),
    delayResize: Duration(milliseconds: 150),
    delaySubmenuOut: Duration(milliseconds: 300),
    delaySkeleton: Duration(milliseconds: 150),
    delayScrollHide: Duration(milliseconds: 800),
    durTypeahead: Duration(milliseconds: 600),
    durToastHold: Duration(milliseconds: 6500),
    durCopied: Duration(milliseconds: 1200),
    durCalmOut: Duration(milliseconds: 180),
    durCalmIn: Duration(milliseconds: 340),
    delayCalmIn: Duration(milliseconds: 60),
    delayCalmReturn: Duration(milliseconds: 650),
  ),

  /// Under Reduce motion (DS tokens/motion.css:71): no movement, every fade unchanged.
  reduced(
    easeState: Cubic(.25, .1, .25, 1),
    easeGlide: Cubic(.32, .72, 0, 1),
    easeExit: Cubic(.4, 0, 1, 1),
    easeLinear: Curves.linear,
    easeLoader: Cubic(.65, .05, .35, .95),
    motion: 0,
    durInstant: Duration.zero,
    durHover: Duration(milliseconds: 120),
    durFocus: Duration(milliseconds: 160),
    durBlink: Duration(milliseconds: 70),
    durMenu: Duration(milliseconds: 110),
    durPop: Duration(milliseconds: 160),
    durExit: Duration(milliseconds: 120),
    durExitLg: Duration(milliseconds: 180),
    durPanel: Duration(milliseconds: 200),
    durDialog: Duration(milliseconds: 220),
    durSlide: Duration(milliseconds: 260),
    durBirth: Duration(milliseconds: 540),
    durFlash: Duration(milliseconds: 2400),
    durSpin: Duration(milliseconds: 800),
    durShimmer: Duration(milliseconds: 1600),
    durNudge: Duration.zero,
    durToggle: Duration.zero,
    durExpand: Duration.zero,
    durMove: Duration.zero,
    durFlip: Duration.zero,
    delayTooltip: Duration(milliseconds: 700),
    durTooltipWarm: Duration(milliseconds: 600),
    delayPeek: Duration(milliseconds: 450),
    delayStackList: Duration(milliseconds: 380),
    delayCallout: Duration(milliseconds: 90),
    delayCalloutOut: Duration(milliseconds: 200),
    delayDropMenu: Duration(milliseconds: 520),
    delaySubmenu: Duration(milliseconds: 150),
    delayResize: Duration(milliseconds: 150),
    delaySubmenuOut: Duration(milliseconds: 300),
    delaySkeleton: Duration(milliseconds: 150),
    delayScrollHide: Duration(milliseconds: 800),
    durTypeahead: Duration(milliseconds: 600),
    durToastHold: Duration(milliseconds: 6500),
    durCopied: Duration(milliseconds: 1200),
    durCalmOut: Duration(milliseconds: 180),
    durCalmIn: Duration(milliseconds: 340),
    delayCalmIn: Duration(milliseconds: 60),
    delayCalmReturn: Duration(milliseconds: 650),
  );

  const ZsMotion({
    required this.easeState,
    required this.easeGlide,
    required this.easeExit,
    required this.easeLinear,
    required this.easeLoader,
    required this.motion,
    required this.durInstant,
    required this.durHover,
    required this.durFocus,
    required this.durBlink,
    required this.durMenu,
    required this.durPop,
    required this.durExit,
    required this.durExitLg,
    required this.durPanel,
    required this.durDialog,
    required this.durSlide,
    required this.durBirth,
    required this.durFlash,
    required this.durSpin,
    required this.durShimmer,
    required this.durNudge,
    required this.durToggle,
    required this.durExpand,
    required this.durMove,
    required this.durFlip,
    required this.delayTooltip,
    required this.durTooltipWarm,
    required this.delayPeek,
    required this.delayStackList,
    required this.delayCallout,
    required this.delayCalloutOut,
    required this.delayDropMenu,
    required this.delaySubmenu,
    required this.delayResize,
    required this.delaySubmenuOut,
    required this.delaySkeleton,
    required this.delayScrollHide,
    required this.durTypeahead,
    required this.durToastHold,
    required this.durCopied,
    required this.durCalmOut,
    required this.durCalmIn,
    required this.delayCalmIn,
    required this.delayCalmReturn,
  });

  /// [reduced] when the nearest `MediaQuery` disables animations, else [full].
  static ZsMotion of(BuildContext context) => (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? reduced : full;

  /// `--ease-state` (DS tokens/motion.css:14).
  final Curve easeState;

  /// `--ease-glide` (DS tokens/motion.css:15).
  final Curve easeGlide;

  /// `--ease-exit` (DS tokens/motion.css:16).
  final Curve easeExit;

  /// `--ease-linear` (DS tokens/motion.css:17).
  final Curve easeLinear;

  /// `--ease-loader` (DS tokens/motion.css:18).
  final Curve easeLoader;

  /// `--motion` (DS tokens/motion.css:20).
  final double motion;

  /// `--dur-instant` (DS tokens/motion.css:23).
  final Duration durInstant;

  /// `--dur-hover` (DS tokens/motion.css:24).
  final Duration durHover;

  /// `--dur-focus` (DS tokens/motion.css:25).
  final Duration durFocus;

  /// `--dur-blink` (DS tokens/motion.css:26).
  final Duration durBlink;

  /// `--dur-menu` (DS tokens/motion.css:27).
  final Duration durMenu;

  /// `--dur-pop` (DS tokens/motion.css:28).
  final Duration durPop;

  /// `--dur-exit` (DS tokens/motion.css:29).
  final Duration durExit;

  /// `--dur-exit-lg` (DS tokens/motion.css:30).
  final Duration durExitLg;

  /// `--dur-panel` (DS tokens/motion.css:31).
  final Duration durPanel;

  /// `--dur-dialog` (DS tokens/motion.css:32).
  final Duration durDialog;

  /// `--dur-slide` (DS tokens/motion.css:33).
  final Duration durSlide;

  /// `--dur-birth` (DS tokens/motion.css:34).
  final Duration durBirth;

  /// `--dur-flash` (DS tokens/motion.css:35).
  final Duration durFlash;

  /// `--dur-spin` (DS tokens/motion.css:36).
  final Duration durSpin;

  /// `--dur-shimmer` (DS tokens/motion.css:37).
  final Duration durShimmer;

  /// `--dur-nudge` (DS tokens/motion.css:40).
  final Duration durNudge;

  /// `--dur-toggle` (DS tokens/motion.css:41).
  final Duration durToggle;

  /// `--dur-expand` (DS tokens/motion.css:42).
  final Duration durExpand;

  /// `--dur-move` (DS tokens/motion.css:43).
  final Duration durMove;

  /// `--dur-flip` (DS tokens/motion.css:44).
  final Duration durFlip;

  /// `--delay-tooltip` (DS tokens/motion.css:47).
  final Duration delayTooltip;

  /// `--dur-tooltip-warm` (DS tokens/motion.css:48).
  final Duration durTooltipWarm;

  /// `--delay-peek` (DS tokens/motion.css:49).
  final Duration delayPeek;

  /// `--delay-stack-list` (DS tokens/motion.css:50).
  final Duration delayStackList;

  /// `--delay-callout` (DS tokens/motion.css:51).
  final Duration delayCallout;

  /// `--delay-callout-out` (DS tokens/motion.css:52).
  final Duration delayCalloutOut;

  /// `--delay-drop-menu` (DS tokens/motion.css:53).
  final Duration delayDropMenu;

  /// `--delay-submenu` (DS tokens/motion.css:54).
  final Duration delaySubmenu;

  /// `--delay-resize` (DS tokens/motion.css:55).
  final Duration delayResize;

  /// `--delay-submenu-out` (DS tokens/motion.css:56).
  final Duration delaySubmenuOut;

  /// `--delay-skeleton` (DS tokens/motion.css:57).
  final Duration delaySkeleton;

  /// `--delay-scroll-hide` (DS tokens/motion.css:58).
  final Duration delayScrollHide;

  /// `--dur-typeahead` (DS tokens/motion.css:59).
  final Duration durTypeahead;

  /// `--dur-toast-hold` (DS tokens/motion.css:60).
  final Duration durToastHold;

  /// `--dur-copied` (DS tokens/motion.css:61).
  final Duration durCopied;

  /// `--dur-calm-out` (DS tokens/motion.css:64).
  final Duration durCalmOut;

  /// `--dur-calm-in` (DS tokens/motion.css:65).
  final Duration durCalmIn;

  /// `--delay-calm-in` (DS tokens/motion.css:66).
  final Duration delayCalmIn;

  /// `--delay-calm-return` (DS tokens/motion.css:67).
  final Duration delayCalmReturn;

  /// Every token as `'--name' → value`; a cubic curve as its four control values, for the DS parity test.
  Map<String, Object> toCss() => <String, Object>{
    '--ease-state': _css(easeState),
    '--ease-glide': _css(easeGlide),
    '--ease-exit': _css(easeExit),
    '--ease-linear': _css(easeLinear),
    '--ease-loader': _css(easeLoader),
    '--motion': motion,
    '--dur-instant': durInstant,
    '--dur-hover': durHover,
    '--dur-focus': durFocus,
    '--dur-blink': durBlink,
    '--dur-menu': durMenu,
    '--dur-pop': durPop,
    '--dur-exit': durExit,
    '--dur-exit-lg': durExitLg,
    '--dur-panel': durPanel,
    '--dur-dialog': durDialog,
    '--dur-slide': durSlide,
    '--dur-birth': durBirth,
    '--dur-flash': durFlash,
    '--dur-spin': durSpin,
    '--dur-shimmer': durShimmer,
    '--dur-nudge': durNudge,
    '--dur-toggle': durToggle,
    '--dur-expand': durExpand,
    '--dur-move': durMove,
    '--dur-flip': durFlip,
    '--delay-tooltip': delayTooltip,
    '--dur-tooltip-warm': durTooltipWarm,
    '--delay-peek': delayPeek,
    '--delay-stack-list': delayStackList,
    '--delay-callout': delayCallout,
    '--delay-callout-out': delayCalloutOut,
    '--delay-drop-menu': delayDropMenu,
    '--delay-submenu': delaySubmenu,
    '--delay-resize': delayResize,
    '--delay-submenu-out': delaySubmenuOut,
    '--delay-skeleton': delaySkeleton,
    '--delay-scroll-hide': delayScrollHide,
    '--dur-typeahead': durTypeahead,
    '--dur-toast-hold': durToastHold,
    '--dur-copied': durCopied,
    '--dur-calm-out': durCalmOut,
    '--dur-calm-in': durCalmIn,
    '--delay-calm-in': delayCalmIn,
    '--delay-calm-return': delayCalmReturn,
  };

  static Object _css(Curve curve) => curve is Cubic ? (curve.a, curve.b, curve.c, curve.d) : curve;
}
